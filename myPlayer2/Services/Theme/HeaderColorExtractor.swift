//
//  HeaderColorExtractor.swift
//  myPlayer2
//
//  Header-specific artwork color extraction with independent caching.
//  Colors are derived from the header artwork itself, not the global playback theme.
//

import AppKit
import SwiftUI

/// Cache entry for header color extraction results.
private final class HeaderColorCacheEntry: NSObject {
    let accentColor: NSColor
    let semanticPalette: SemanticPalette
    let checksum: UInt64

    init(accentColor: NSColor, semanticPalette: SemanticPalette, checksum: UInt64) {
        self.accentColor = accentColor
        self.semanticPalette = semanticPalette
        self.checksum = checksum
    }
}

/// Extracts colors from header artwork independently of the global ThemeStore.
/// Results are cached in memory keyed by artwork identity + data checksum.
@MainActor
final class HeaderColorExtractor {
    static let shared = HeaderColorExtractor()

    private let cache = NSCache<NSString, HeaderColorCacheEntry>()
    private let extractionQueue = DispatchQueue(
        label: "kmg.myPlayer2.headerColor.extraction",
        qos: .userInitiated
    )
    private var activeToken = UUID()

    private init() {
        cache.countLimit = 32
        cache.totalCostLimit = 2 * 1024 * 1024
    }

    /// Extract a header-specific accent color and semantic palette from artwork data.
    /// - Parameters:
    ///   - data: The artwork image data.
    ///   - artworkIdentity: A stable identity string for this header artwork (e.g. DetailHeaderConfig.artworkIdentity).
    /// - Returns: A tuple of (accentColor, semanticPalette) suitable for header UI controls.
    func extract(
        from data: Data,
        artworkIdentity: String
    ) async -> (accent: Color, palette: SemanticPalette)? {
        let checksum = ColorMath.fnv1a(data)
        let cacheKey = "\(artworkIdentity)-\(checksum)" as NSString

        // Memory cache hit
        if let cached = cache.object(forKey: cacheKey), cached.checksum == checksum {
            Log.trace("HeaderColor cache hit for \(shortIdentity(artworkIdentity))", category: .theme)
            return (
                Color(nsColor: cached.accentColor),
                cached.semanticPalette
            )
        }

        // Async extraction
        let token = UUID()
        activeToken = token

        let result = await extractInBackground(data: data, checksum: checksum)

        guard token == activeToken else {
            Log.trace("HeaderColor token mismatch, discarding result", category: .theme)
            return nil
        }

        guard let (accentNS, palette) = result else { return nil }

        // Cache result
        let entry = HeaderColorCacheEntry(
            accentColor: accentNS,
            semanticPalette: palette,
            checksum: checksum
        )
        cache.setObject(entry, forKey: cacheKey)

        Log.debug(
            "HeaderColor extracted for \(shortIdentity(artworkIdentity)) accent=\(formatColor(accentNS))",
            category: .theme
        )

        return (Color(nsColor: accentNS), palette)
    }

    /// Reset the active token to cancel any in-flight extraction.
    func cancelPending() {
        activeToken = UUID()
    }

    // MARK: - Private

    private func extractInBackground(
        data: Data,
        checksum: UInt64
    ) async -> (NSColor, SemanticPalette)? {
        await withCheckedContinuation { continuation in
            extractionQueue.async {
                guard let analysis = ArtworkColorExtractor.analyze(from: data) else {
                    continuation.resume(returning: nil)
                    return
                }

                // Use the same semantic palette factory as the rest of the app,
                // but with artwork-tint always enabled since the header color
                // should always derive from its own artwork.
                let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let scheme: ColorScheme = isDark ? .dark : .light

                let palette = SemanticPaletteFactory.make(
                    from: analysis,
                    scheme: scheme,
                    userFallbackAccent: NSColor(AppSettings.shared.accentColor),
                    useArtworkTint: true
                )

                continuation.resume(returning: (palette.globalAccent, palette))
            }
        }
    }

    private func shortIdentity(_ identity: String) -> String {
        String(identity.prefix(24))
    }

    private func formatColor(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return "?" }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return "rgb(\(r),\(g),\(b))"
    }
}

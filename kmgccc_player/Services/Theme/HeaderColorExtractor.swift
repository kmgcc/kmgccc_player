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
    let semanticPalette: SemanticPalette?
    let foregroundPalette: AppForegroundPalette?
    let checksum: UInt64

    init(
        accentColor: NSColor,
        semanticPalette: SemanticPalette?,
        foregroundPalette: AppForegroundPalette?,
        checksum: UInt64
    ) {
        self.accentColor = accentColor
        self.semanticPalette = semanticPalette
        self.foregroundPalette = foregroundPalette
        self.checksum = checksum
    }
}

private struct HeaderColorPersistentEntry: Codable {
    let cacheVersion: String
    let artworkIdentity: String
    let isDark: Bool
    let checksum: UInt64
    let accent: CodableColor
    let foreground: CodableForegroundPalette
    let cachedAt: Date
}

private struct CodableForegroundPalette: Codable {
    let primary: CodableColor
    let secondary: CodableColor
    let tertiary: CodableColor
    let quaternary: CodableColor
    let disabled: CodableColor
}

private struct CodableColor: Codable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat
}

/// Extracts colors from header artwork independently of the global ThemeStore.
/// Results are cached in memory keyed by artwork identity + data checksum.
@MainActor
final class HeaderColorExtractor {
    static let shared = HeaderColorExtractor(cacheDirectory: StorageLocations.headerColorCacheURL)

    private let persistentCacheDirectory: URL
    private let cache = NSCache<NSString, HeaderColorCacheEntry>()
    private let latestByIdentityCache = NSCache<NSString, HeaderColorCacheEntry>()
    private let extractionQueue = DispatchQueue(
        label: "kmg.kmgccc_player.headerColor.extraction",
        qos: .userInitiated
    )

    convenience init(storage: LibraryStorageLocations) {
        self.init(cacheDirectory: storage.headerColorCacheURL)
    }

    private init(cacheDirectory: URL) {
        self.persistentCacheDirectory = cacheDirectory
        cache.countLimit = 32
        cache.totalCostLimit = 2 * 1024 * 1024
        latestByIdentityCache.countLimit = 32
    }

    /// Return the most recent cached palette for this artwork identity.
    /// `DetailHeaderConfig.artworkIdentity` includes the playlist/artist/album
    /// artwork revision, so this is safe as an instant first-paint hint.
    func cachedResult(
        artworkIdentity: String,
        isDark: Bool? = nil
    ) -> (accent: Color, palette: SemanticPalette?, foreground: AppForegroundPalette?, checksum: UInt64)? {
        let dark = isDark ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        let identityCacheKey = "\(artworkIdentity)-\(dark ? "dark" : "light")" as NSString
        if let cached = latestByIdentityCache.object(forKey: identityCacheKey) {
            return renderedResult(from: cached)
        }
        guard let persisted = loadPersistentEntry(artworkIdentity: artworkIdentity, isDark: dark) else {
            return nil
        }
        latestByIdentityCache.setObject(persisted, forKey: identityCacheKey)
        return renderedResult(from: persisted)
    }

    /// Extract a header-specific accent color and semantic palette from artwork data.
    /// - Parameters:
    ///   - data: The artwork image data.
    ///   - artworkIdentity: A stable identity string for this header artwork (e.g. DetailHeaderConfig.artworkIdentity).
    ///   - isDark: Override the color scheme lookup.
    /// - Returns: A tuple of (accentColor, semanticPalette) suitable for header UI controls.
    func extract(
        from data: Data,
        artworkIdentity: String,
        isDark: Bool? = nil
    ) async -> (accent: Color, palette: SemanticPalette)? {
        let checksum = ColorMath.fnv1a(data)
        let dark = isDark ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        let cacheKey = "\(artworkIdentity)-\(checksum)-\(dark ? "dark" : "light")" as NSString
        let identityCacheKey = "\(artworkIdentity)-\(dark ? "dark" : "light")" as NSString

        // Memory cache hit
        if let cached = cache.object(forKey: cacheKey), cached.checksum == checksum {
            Log.trace("HeaderColor cache hit for \(shortIdentity(artworkIdentity))", category: .theme)
            latestByIdentityCache.setObject(cached, forKey: identityCacheKey)
            let rendered = renderedResult(from: cached)
            if let palette = rendered.palette {
                return (rendered.accent, palette)
            }
        }

        let result = await extractInBackground(data: data, checksum: checksum, isDark: dark)
        guard let (accentNS, palette) = result else { return nil }

        // Cache result
        let entry = HeaderColorCacheEntry(
            accentColor: accentNS,
            semanticPalette: palette,
            foregroundPalette: palette.appForeground,
            checksum: checksum
        )
        cache.setObject(entry, forKey: cacheKey)
        latestByIdentityCache.setObject(entry, forKey: identityCacheKey)
        persist(entry, artworkIdentity: artworkIdentity, isDark: dark)

        Log.debug(
            "HeaderColor extracted for \(shortIdentity(artworkIdentity)) accent=\(formatColor(accentNS))",
            category: .theme
        )

        return (ColorRenderingAdapter.makeSwiftUIColor(accentNS), palette)
    }

    func clearMemory() {
        cache.removeAllObjects()
        latestByIdentityCache.removeAllObjects()
    }

    /// Compatibility hook for callers that cancel their own extraction tasks.
    func cancelPending() {
        // Cancellation is owned by each PlaylistPageController task. Keeping
        // this method as a no-op preserves call-site intent without letting one
        // header invalidate another header's extraction result globally.
    }

    // MARK: - Private

    private func extractInBackground(
        data: Data,
        checksum: UInt64,
        isDark: Bool
    ) async -> (NSColor, SemanticPalette)? {
        let scheme: ColorScheme = isDark ? .dark : .light
        // Resolve the dynamic accent color while on MainActor.
        let accentBase = NSColor(AppSettings.shared.accentColor)
            .usingColorSpace(.deviceRGB) ?? NSColor(deviceRed: 0.9, green: 0.78, blue: 0.6, alpha: 1)
        let accentR = accentBase.redComponent
        let accentG = accentBase.greenComponent
        let accentB = accentBase.blueComponent

        return await withCheckedContinuation { continuation in
            extractionQueue.async {
                guard let analysis = ArtworkColorExtractor.analyze(from: data) else {
                    continuation.resume(returning: nil)
                    return
                }

                let fallbackAccent = NSColor(deviceRed: accentR, green: accentG, blue: accentB, alpha: 1)
                let palette = SemanticPaletteFactory.make(
                    from: analysis,
                    scheme: scheme,
                    userFallbackAccent: fallbackAccent,
                    useArtworkTint: true
                )

                continuation.resume(returning: (palette.globalAccent, palette))
            }
        }
    }

    private func renderedResult(
        from cached: HeaderColorCacheEntry
    ) -> (accent: Color, palette: SemanticPalette?, foreground: AppForegroundPalette?, checksum: UInt64) {
        (
            ColorRenderingAdapter.makeSwiftUIColor(cached.accentColor),
            cached.semanticPalette,
            cached.foregroundPalette ?? cached.semanticPalette?.appForeground,
            cached.checksum
        )
    }

    private func loadPersistentEntry(artworkIdentity: String, isDark: Bool) -> HeaderColorCacheEntry? {
        let url = persistentFileURL(artworkIdentity: artworkIdentity, isDark: isDark)
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(HeaderColorPersistentEntry.self, from: data),
              record.cacheVersion == ArtworkColorExtractor.cacheVersion,
              record.artworkIdentity == artworkIdentity,
              record.isDark == isDark
        else {
            return nil
        }

        let entry = HeaderColorCacheEntry(
            accentColor: record.accent.nsColor,
            semanticPalette: nil,
            foregroundPalette: record.foreground.palette,
            checksum: record.checksum
        )
        Log.trace("HeaderColor disk cache hit for \(shortIdentity(artworkIdentity))", category: .theme)
        return entry
    }

    private func persist(_ entry: HeaderColorCacheEntry, artworkIdentity: String, isDark: Bool) {
        let foreground = entry.foregroundPalette ?? entry.semanticPalette?.appForeground
        guard let foreground else { return }
        let record = HeaderColorPersistentEntry(
            cacheVersion: ArtworkColorExtractor.cacheVersion,
            artworkIdentity: artworkIdentity,
            isDark: isDark,
            checksum: entry.checksum,
            accent: CodableColor(entry.accentColor),
            foreground: CodableForegroundPalette(foreground),
            cachedAt: Date()
        )
        let url = persistentFileURL(artworkIdentity: artworkIdentity, isDark: isDark)
        do {
            try FileManager.default.createDirectory(
                at: persistentCacheDirectory,
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(record)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.warning("Failed to persist header color cache: \(error.localizedDescription)", category: .theme)
        }
    }

    private func persistentFileURL(artworkIdentity: String, isDark: Bool) -> URL {
        let key = "\(ArtworkColorExtractor.cacheVersion)|\(artworkIdentity)|\(isDark ? "dark" : "light")"
        return persistentCacheDirectory.appendingPathComponent("\(stableDigest(key)).json")
    }

    private func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
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

private extension CodableColor {
    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.deviceRGB)
            ?? NSColor(deviceRed: 0.9, green: 0.78, blue: 0.6, alpha: 1)
        red = rgb.redComponent
        green = rgb.greenComponent
        blue = rgb.blueComponent
        alpha = rgb.alphaComponent
    }

    var nsColor: NSColor {
        NSColor(deviceRed: red, green: green, blue: blue, alpha: alpha)
    }
}

private extension CodableForegroundPalette {
    init(_ palette: AppForegroundPalette) {
        primary = CodableColor(palette.primary)
        secondary = CodableColor(palette.secondary)
        tertiary = CodableColor(palette.tertiary)
        quaternary = CodableColor(palette.quaternary)
        disabled = CodableColor(palette.disabled)
    }

    var palette: AppForegroundPalette {
        AppForegroundPalette(
            primary: primary.nsColor,
            secondary: secondary.nsColor,
            tertiary: tertiary.nsColor,
            quaternary: quaternary.nsColor,
            disabled: disabled.nsColor
        )
    }
}

//
//  ThemeStore.swift
//  myPlayer2
//
//  kmgccc_player - Unified Theme Management
//  Manages color scheme and computed palette for the application.
//

import AppKit
import Combine
import SwiftUI

private final class NSColorBox: NSObject {
    let color: NSColor
    init(_ color: NSColor) { self.color = color }
}

/// Final computed colors for the application theme.
struct ThemePalette: Equatable {
    let scheme: ColorScheme
    let background: String
    let text: String
    let activeLine: String
    let inactiveLine: String
    let accent: String
    let shadow: String
}

/// Global theme manager that resolves "Color Sources" (artwork, system accent)
/// and adapts them to the current color scheme.
@MainActor
final class ThemeStore: ObservableObject {

    static let shared = ThemeStore()

    @Published var colorScheme: ColorScheme = .dark
    @Published var palette: ThemePalette?
    @Published private(set) var baseColor: Color
    @Published private(set) var accentColor: Color
    @Published private(set) var accentNSColor: NSColor
    @Published private(set) var artworkBaseNSColor: NSColor
    @Published private(set) var hasArtworkThemeColor: Bool = false
    @Published private(set) var selectionFill: Color
    @Published private(set) var usesFallbackThemeColor: Bool = true
    @Published private(set) var analysis: ArtworkColorAnalysis = .neutralFallback
    @Published private(set) var semanticPalette: SemanticPalette

    let defaultBlue: Color

    private let defaultBlueNS: NSColor
    private var rawDominantColor: NSColor
    private let dominantColorCache = NSCache<NSString, NSColorBox>()
    private var activeArtworkIdentity: String?
    private var extractionToken = UUID()
    private let extractionQueue = DispatchQueue(
        label: "kmg.myPlayer2.theme.artwork.extraction",
        qos: .userInitiated
    )

    private var currentArtworkData: Data?
    private var currentArtworkChecksum: UInt64 = 0
    private var lastProcessedChecksum: UInt64 = 0
    private var lastProcessedArtworkIdentity: String?
    private var averageColorCache: NSColor?

    private init() {
        // Default theme color: soft warm yellow (desaturated for calmer appearance)
        let fallback = NSColor(
            calibratedRed: 255.0 / 255.0,
            green: 200.0 / 255.0,
            blue: 120.0 / 255.0,
            alpha: 1.0
        )
        self.defaultBlueNS = fallback
        self.rawDominantColor = fallback
        self.defaultBlue = Color(nsColor: fallback)
        self.baseColor = Color(nsColor: fallback)
        self.accentColor = Color(nsColor: fallback)
        self.accentNSColor = fallback
        self.artworkBaseNSColor = fallback
        self.selectionFill = Color(nsColor: fallback).opacity(0.14)
        self.semanticPalette = SemanticPaletteFactory.make(
            from: .neutralFallback,
            scheme: .dark,
            userFallbackAccent: fallback,
            useArtworkTint: AppSettings.shared.globalArtworkTintEnabled
        )

        dominantColorCache.countLimit = 50

        // Initial palette generation
        Task {
            await refreshPalette(reason: "init")
        }
    }

    /// Legacy entrypoint kept for compatibility with old call sites.
    func updateArtwork(_ data: Data?) async {
        await updateThemeFromArtworkData(data, artworkIdentity: nil, assetTrackID: nil)
    }

    /// Primary entrypoint: update theme based on current track.
    /// - Uses artwork identity cache to avoid repeated extraction on the same artwork.
    /// - Falls back to default blue when artwork is missing or extraction fails.
    func updateTheme(for track: Track?) async {
        let trackID = track?.id
        let artworkData = track?.artworkData
        await updateThemeFromArtworkData(
            artworkData,
            artworkIdentity: trackID?.uuidString,
            assetTrackID: trackID
        )
    }

    /// Source-neutral artwork theme entrypoint.
    /// Local playback supplies a Track; external playback supplies presentation artwork and identity.
    func updateTheme(for presentation: NowPlayingPresentation) async {
        if presentation.source == .local {
            await updateTheme(for: presentation.localTrack)
            return
        }

        let artworkIdentity =
            presentation.artworkIdentity
            ?? presentation.externalStableKey
            ?? presentation.lyricsIdentity

        await updateThemeFromArtworkData(
            presentation.artworkData,
            artworkIdentity: artworkIdentity,
            assetTrackID: presentation.localTrack?.id
        )
    }

    private func updateThemeFromArtworkData(
        _ data: Data?,
        artworkIdentity: String?,
        assetTrackID: UUID?
    ) async {
        let checksum = data.map(computeChecksum) ?? 0
        let updateState = "identity=\(artworkIdentity ?? "nil")|checksum=\(checksum)"
        if await LogStateTracker.shared.checkStateChanged(
            key: "theme.updateThemeFromArtworkData",
            value: updateState
        ) {
            Log.debug(
                "updateThemeFromArtworkData called - identity: \(shortIdentity(artworkIdentity)), dataSize: \(data?.count ?? 0)",
                category: .theme
            )
        }

        if await LogStateTracker.shared.checkStateChanged(
            key: "theme.checksumComputation",
            value: updateState
        ) {
            Log.debug(
                "checksum computed: \(checksum), lastProcessedChecksum: \(lastProcessedChecksum), lastProcessedIdentity: \(shortIdentity(lastProcessedArtworkIdentity))",
                category: .theme
            )
        }

        guard let data, data.isEmpty == false else {
            Log.debug("No artwork data, resetting to default", category: .theme)
            currentArtworkData = nil
            currentArtworkChecksum = 0
            lastProcessedChecksum = 0
            lastProcessedArtworkIdentity = nil
            averageColorCache = nil
            analysis = .neutralFallback
            rawDominantColor = defaultBlueNS
            hasArtworkThemeColor = false
            usesFallbackThemeColor = true
            await refreshPalette(reason: "track_missing_artwork")
            return
        }

        let cacheKey = makeCacheKey(artworkIdentity: artworkIdentity, checksum: checksum)

        if artworkIdentity == activeArtworkIdentity, checksum == currentArtworkChecksum, checksum != 0 {
            Log.trace(
                "Already processing artwork checksum \(checksum), skipping duplicate in-flight call",
                category: .theme
            )
            return
        }

        activeArtworkIdentity = artworkIdentity
        extractionToken = UUID()
        let token = extractionToken

        // Deduplication: palette extraction depends on artwork bytes; identity may change when AM upgrades source.
        if checksum == lastProcessedChecksum, checksum != 0 {
            lastProcessedArtworkIdentity = artworkIdentity
            Log.trace(
                "Skipping duplicate artwork (checksum match: \(checksum))",
                category: .theme
            )
            return
        }

        currentArtworkData = data
        currentArtworkChecksum = checksum
        averageColorCache = nil
        hasArtworkThemeColor = false
        
        Log.trace("Cleared averageColorCache for new track", category: .theme)

        if let cacheKey, let cached = dominantColorCache.object(forKey: cacheKey as NSString)?.color {
            Log.debug("Cache hit for dominant color cache key \(cacheKey)", category: .theme)
            rawDominantColor = cached
            hasArtworkThemeColor = true
            usesFallbackThemeColor = false
            lastProcessedChecksum = checksum
            lastProcessedArtworkIdentity = artworkIdentity
            if let assetTrackID {
                averageColorCache = await ArtworkAssetStore.shared
                    .get(trackID: assetTrackID, artworkChecksum: checksum)?
                    .averageColor
            }
            await refreshPalette(reason: "track_artwork_cached")
            return
        }

        Log.debug(
            "Extraction started for identity \(shortIdentity(artworkIdentity))",
            category: .theme
        )

        // Quick color for immediate UI feedback, then full extraction
        async let quick = extractQuickColor(from: data)
        async let cachedArtworkSnapshot: ArtworkAssetSnapshot? = {
            guard let assetTrackID else { return nil }
            return await ArtworkAssetStore.shared.snapshotMetadata(trackID: assetTrackID, artworkData: data)
        }()

        // Apply quick color first for immediate feedback
        if let quickColor = await quick, token == extractionToken, activeArtworkIdentity == artworkIdentity {
            Log.trace("Applying quick color", category: .theme)
            rawDominantColor = quickColor
            hasArtworkThemeColor = true
            usesFallbackThemeColor = false
            await refreshPalette(reason: "track_artwork_quick")
        }

        // Then apply full extraction
        let artworkSnapshot = await cachedArtworkSnapshot
        let extractedColor: NSColor?
        if let snapshotColor = artworkSnapshot?.accentColor ?? artworkSnapshot?.dominantColor {
            extractedColor = snapshotColor
        } else {
            extractedColor = await extractDominantColor(from: data)
        }
        let extractedAnalysis = await extractAnalysis(from: data)

        guard token == extractionToken, activeArtworkIdentity == artworkIdentity else {
            Log.trace(
                "Token/identity mismatch, aborting. token match: \(token == extractionToken), activeIdentity match: \(activeArtworkIdentity == artworkIdentity), currentActiveIdentity: \(shortIdentity(activeArtworkIdentity)), expectedIdentity: \(shortIdentity(artworkIdentity))",
                category: .theme
            )
            return
        }

        Log.trace("Applying extracted color", category: .theme)
        
        let resolved = extractedColor ?? rawDominantColor
        if let cacheKey {
            dominantColorCache.setObject(NSColorBox(resolved), forKey: cacheKey as NSString)
        }
        rawDominantColor = resolved
        self.analysis = extractedAnalysis ?? .neutralFallback
        hasArtworkThemeColor = extractedColor != nil || hasArtworkThemeColor
        usesFallbackThemeColor = !hasArtworkThemeColor
        lastProcessedChecksum = checksum
        lastProcessedArtworkIdentity = artworkIdentity
        
        // Pre-extract and cache averageColor
        if extractedColor != nil {
            if let cachedAverageColor = artworkSnapshot?.averageColor {
                averageColorCache = cachedAverageColor
            } else {
                averageColorCache = await extractAverageColor(from: data)
            }
        }
        
        await refreshPalette(reason: "track_artwork_extracted")
    }

    private func extractDominantColor(from data: Data) async -> NSColor? {
        await withCheckedContinuation { continuation in
            extractionQueue.async {
                let raw =
                    ArtworkColorExtractor.uiAccentColor(from: data)
                    ?? ArtworkColorExtractor.averageColor(from: data)
                continuation.resume(returning: raw)
            }
        }
    }

    private func extractQuickColor(from data: Data) async -> NSColor? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: ArtworkColorExtractor.quickAccentSample(from: data))
            }
        }
    }

    private func extractAverageColor(from data: Data) async -> NSColor? {
        await withCheckedContinuation { continuation in
            extractionQueue.async {
                continuation.resume(returning: ArtworkColorExtractor.averageColor(from: data))
            }
        }
    }

    private func extractAnalysis(from data: Data) async -> ArtworkColorAnalysis? {
        await withCheckedContinuation { continuation in
            extractionQueue.async {
                continuation.resume(returning: ArtworkColorExtractor.analyze(from: data))
            }
        }
    }

    /// Re-calculate the palette based on scheme and artwork.
    func refreshPalette(reason: String) async {
        let isDark = colorScheme == .dark
        let schemeState = isDark ? "dark" : "light"
        let shouldLogRefresh = await LogStateTracker.shared.checkStateChanged(
            key: "theme.refreshPalette.scheme",
            value: schemeState
        )
        if shouldLogRefresh {
            Log.trace(
                "schemeChanged -> refreshPalette (reason=\(reason), isDark=\(isDark))",
                category: .theme
            )
        }

        let semantic = SemanticPaletteFactory.make(
            from: analysis,
            scheme: colorScheme,
            userFallbackAccent: NSColor(AppSettings.shared.accentColor),
            useArtworkTint: AppSettings.shared.globalArtworkTintEnabled && hasArtworkThemeColor
        )
        let resolvedAccentNS = semantic.globalAccent
        let fillAlpha = colorScheme == .dark ? 0.20 : 0.14
        withAnimation(.easeInOut(duration: 0.20)) {
            baseColor = Color(nsColor: rawDominantColor)
            accentColor = Color(nsColor: resolvedAccentNS)
            accentNSColor = resolvedAccentNS
            artworkBaseNSColor = rawDominantColor
            selectionFill = Color(nsColor: resolvedAccentNS).opacity(fillAlpha)
            semanticPalette = semantic
        }

        // Default fallbacks
        var bg = isDark ? "rgba(20, 20, 20, 0.85)" : "rgba(245, 245, 245, 0.85)"
        var text = isDark ? "rgba(255, 255, 255, 0.95)" : "rgba(30, 30, 30, 0.95)"
        var active = isDark ? "rgba(255, 255, 255, 1.0)" : "rgba(0, 0, 0, 1.0)"
        var inactive = isDark ? "rgba(255, 255, 255, 0.35)" : "rgba(0, 0, 0, 0.35)"
        var accent = ArtworkColorExtractor.cssRGBA(resolvedAccentNS, alpha: 1.0)
        var shadow = isDark ? "rgba(0, 0, 0, 0.3)" : "rgba(0, 0, 0, 0.1)"

        // If we have artwork, perform adaptive extraction
        if let data = currentArtworkData {
            // Use cached averageColor if available, otherwise compute it
            let avgColor = averageColorCache ?? ArtworkColorExtractor.averageColor(from: data)
            
            if let rawColor = avgColor {
                // Adjusted for readability in current scheme
                let adjusted = ArtworkColorExtractor.adjustedAccent(
                    from: rawColor, isDarkMode: isDark)

                text = ArtworkColorExtractor.cssRGBA(adjusted, alpha: 0.95)
                active = ArtworkColorExtractor.cssRGBA(adjusted, alpha: 1.0)
                inactive = ArtworkColorExtractor.cssRGBA(adjusted, alpha: 0.35)
                accent = ArtworkColorExtractor.cssRGBA(resolvedAccentNS, alpha: 1.0)

                if isDark {
                    bg = "rgba(15, 15, 15, 0.7)"
                    shadow = "rgba(0, 0, 0, 0.5)"
                } else {
                    bg = "rgba(250, 250, 250, 0.7)"
                    shadow = "rgba(0, 0, 0, 0.15)"
                }
            }
        }

        let newPalette = ThemePalette(
            scheme: colorScheme,
            background: bg,
            text: text,
            activeLine: active,
            inactiveLine: inactive,
            accent: accent,
            shadow: shadow
        )

        let paletteChanged = palette != newPalette
        let paletteSignature = [
            newPalette.scheme == .dark ? "dark" : "light",
            newPalette.background,
            newPalette.text,
            newPalette.activeLine,
            newPalette.inactiveLine,
            newPalette.accent,
            newPalette.shadow,
        ].joined(separator: "|")
        let shouldLogApplyTheme = await LogStateTracker.shared.checkStateChanged(
            key: "theme.applyTheme.palette",
            value: paletteSignature
        )
        self.palette = newPalette

        if shouldLogRefresh {
            Log.trace(
                "refreshPalette details: reason=\(reason), accent=\(accent), background=\(bg), text=\(text)",
                category: .theme
            )
        }

        if paletteChanged {
            Log.debug(
                "Theme applied (reason=\(reason), scheme=\(schemeState), fallback=\(usesFallbackThemeColor))",
                category: .theme
            )
        }

        if shouldLogApplyTheme {
            Log.debug("applyTheme -> all surfaces", category: .theme)
        }

        // Push to AMLL via surface manager
        LyricsSurfaceManager.shared.applyTheme(newPalette)
    }

    var textColor: Color {
        guard let css = palette?.text, let color = Color(rgbaString: css) else {
            return .primary
        }
        return color
    }

    var secondaryTextColor: Color {
        guard let css = palette?.inactiveLine, let color = Color(rgbaString: css) else {
            return .secondary
        }
        return color
    }

    var backgroundColor: Color {
        guard let css = palette?.background, let color = Color(rgbaString: css) else {
            return Color(nsColor: .windowBackgroundColor)
        }
        return color
    }

    private nonisolated func computeChecksum(_ data: Data) -> UInt64 {
        ColorMath.fnv1a(data)
    }
    
    private func makeCacheKey(artworkIdentity: String?, checksum: UInt64) -> String? {
        guard let artworkIdentity, checksum != 0 else { return nil }
        return "\(artworkIdentity)-\(checksum)"
    }

    private func shortIdentity(_ identity: String?) -> String {
        guard let identity, !identity.isEmpty else { return "nil" }
        return String(identity.prefix(16))
    }
}

// MARK: - Color Extension (RGBA Parser)

extension Color {
    init?(rgbaString: String) {
        // Expected format: "rgba(r, g, b, a)" or "rgb(r, g, b)"
        let clean = rgbaString.replacingOccurrences(of: "rgba(", with: "")
            .replacingOccurrences(of: "rgb(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: " ", with: "")

        let components = clean.split(separator: ",")
        guard components.count >= 3 else { return nil }

        guard let r = Double(components[0]),
            let g = Double(components[1]),
            let b = Double(components[2])
        else { return nil }

        let a = components.count > 3 ? Double(components[3]) ?? 1.0 : 1.0

        self.init(red: r / 255.0, green: g / 255.0, blue: b / 255.0, opacity: a)
    }
}

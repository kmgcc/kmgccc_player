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

/// Final computed colors for the application theme.
struct ThemePalette {
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
    // Keep dynamic accent bright enough in dark mode so icon glyphs stay readable.
    static let darkModeMinimumThemeBrightness: CGFloat = 0.56
    static let darkModeMinimumThemeLightness: CGFloat = 0.56

    @Published var colorScheme: ColorScheme = .dark
    @Published var palette: ThemePalette?
    @Published private(set) var baseColor: Color
    @Published private(set) var accentColor: Color
    @Published private(set) var accentNSColor: NSColor
    @Published private(set) var selectionFill: Color
    @Published private(set) var usesFallbackThemeColor: Bool = true

    let defaultBlue: Color

    private let defaultBlueNS: NSColor
    private var rawDominantColor: NSColor
    private var dominantColorCache: [UUID: NSColor] = [:]
    private var activeTrackID: UUID?
    private var extractionToken = UUID()
    private let extractionQueue = DispatchQueue(
        label: "kmg.myPlayer2.theme.artwork.extraction",
        qos: .userInitiated
    )

    private var currentArtworkData: Data?

    private init() {
        // Default theme color: light orange-red.
        let fallback = NSColor(
            calibratedRed: 255.0 / 255.0,
            green: 150.0 / 255.0,
            blue: 50.0 / 255.0,
            alpha: 1.0
        )
        self.defaultBlueNS = fallback
        self.rawDominantColor = fallback
        self.defaultBlue = Color(nsColor: fallback)
        self.baseColor = Color(nsColor: fallback)
        self.accentColor = Color(nsColor: fallback)
        self.accentNSColor = fallback
        self.selectionFill = Color(nsColor: fallback).opacity(0.14)

        // Initial palette generation
        Task {
            await refreshPalette(reason: "init")
        }
    }

    /// Legacy entrypoint kept for compatibility with old call sites.
    func updateArtwork(_ data: Data?) async {
        await updateThemeFromArtworkData(data, trackID: nil)
    }

    /// Primary entrypoint: update theme based on current track.
    /// - Uses trackID cache to avoid repeated extraction on same song.
    /// - Falls back to default blue when artwork is missing or extraction fails.
    func updateTheme(for track: Track?) async {
        let trackID = track?.id
        let artworkData = track?.artworkData
        await updateThemeFromArtworkData(artworkData, trackID: trackID)
    }

    private func updateThemeFromArtworkData(_ data: Data?, trackID: UUID?) async {
        activeTrackID = trackID
        extractionToken = UUID()
        let token = extractionToken

        guard let data, data.isEmpty == false else {
            currentArtworkData = nil
            rawDominantColor = defaultBlueNS
            usesFallbackThemeColor = true
            await refreshPalette(reason: "track_missing_artwork")
            return
        }

        currentArtworkData = data

        if let trackID, let cached = dominantColorCache[trackID] {
            rawDominantColor = cached
            usesFallbackThemeColor = false
            await refreshPalette(reason: "track_artwork_cached")
            return
        }

        async let quick = extractQuickColor(from: data)
        async let extracted = extractDominantColor(from: data)

        if let quickColor = await quick, token == extractionToken, activeTrackID == trackID {
            rawDominantColor = quickColor
            usesFallbackThemeColor = false
            await refreshPalette(reason: "track_artwork_quick")
        }

        let extractedColor = await extracted

        guard token == extractionToken, activeTrackID == trackID else {
            return
        }

        let resolved = extractedColor ?? rawDominantColor
        if let trackID {
            dominantColorCache[trackID] = resolved
        }
        rawDominantColor = resolved
        usesFallbackThemeColor = extractedColor == nil
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

    /// Re-calculate the palette based on scheme and artwork.
    func refreshPalette(reason: String) async {
        let isDark = colorScheme == .dark
        print("[Theme] schemeChanged -> refreshPalette (reason=\(reason), isDark=\(isDark))")

        let optimizedArtworkAccent = optimizeAccentColor(rawDominantColor, scheme: colorScheme)
        let defaultAccentNS = NSColor(AppSettings.shared.accentColor)
        let resolvedAccentNS =
            AppSettings.shared.globalArtworkTintEnabled ? optimizedArtworkAccent : defaultAccentNS
        let fillAlpha = colorScheme == .dark ? 0.20 : 0.14
        withAnimation(.easeInOut(duration: 0.20)) {
            baseColor = Color(nsColor: rawDominantColor)
            accentColor = Color(nsColor: resolvedAccentNS)
            accentNSColor = resolvedAccentNS
            selectionFill = Color(nsColor: resolvedAccentNS).opacity(fillAlpha)
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
            if let rawColor = ArtworkColorExtractor.averageColor(from: data) {
                // Adjusted for readability in current scheme
                let adjusted = ArtworkColorExtractor.adjustedAccent(
                    from: rawColor, isDarkMode: isDark)

                text = ArtworkColorExtractor.cssRGBA(adjusted, alpha: 0.95)
                active = ArtworkColorExtractor.cssRGBA(adjusted, alpha: 1.0)
                inactive = ArtworkColorExtractor.cssRGBA(adjusted, alpha: 0.35)
                accent = ArtworkColorExtractor.cssRGBA(resolvedAccentNS, alpha: 1.0)

                // Deepen/Brighten background based on adjusted color if needed,
                // but usually we keep it neutral glass for now.
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

        self.palette = newPalette

        // Push to AMLL
        print("[Theme] applyTheme -> replaySnapshot")
        LyricsWebViewStore.shared.applyTheme(newPalette)
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

    private func optimizeAccentColor(_ color: NSColor, scheme: ColorScheme) -> NSColor {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return defaultBlueNS }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        // Step 1: remove dirty/gray and over-dark colors.
        saturation = max(saturation, 0.24)
        brightness = max(brightness, 0.22)

        // Step 2: visibility optimization by mode.
        if scheme == .dark {
            saturation = min(max(saturation * 1.06, 0.30), 0.90)
            brightness = min(max(brightness * 1.10, 0.62), 0.88)
            brightness = max(brightness, Self.darkModeMinimumThemeBrightness)
        } else {
            saturation = min(max(saturation * 1.02, 0.28), 0.78)
            brightness = min(max(brightness * 0.88, 0.28), 0.68)
        }

        let optimized = NSColor(
            calibratedHue: hue,
            saturation: saturation,
            brightness: brightness,
            alpha: 1.0
        )
        if scheme == .dark {
            return enforceMinimumLightnessForDarkMode(optimized)
        }
        return optimized
    }

    private func enforceMinimumLightnessForDarkMode(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return color }
        let r = clamp(rgb.redComponent, min: 0, max: 1)
        let g = clamp(rgb.greenComponent, min: 0, max: 1)
        let b = clamp(rgb.blueComponent, min: 0, max: 1)

        let maxV = max(r, max(g, b))
        let minV = min(r, min(g, b))
        var h: CGFloat = 0
        let l = (maxV + minV) * 0.5
        let delta = maxV - minV

        if delta > 0.000_001 {
            if maxV == r {
                h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxV == g {
                h = ((b - r) / delta) + 2
            } else {
                h = ((r - g) / delta) + 4
            }
            h /= 6
            if h < 0 { h += 1 }
        }

        var s: CGFloat = 0
        if delta > 0.000_001 {
            s = delta / (1 - abs(2 * l - 1))
        }

        let targetL = max(l, Self.darkModeMinimumThemeLightness)
        if targetL <= l + 0.000_001 { return color }

        let c = (1 - abs(2 * targetL - 1)) * s
        let hPrime = h * 6
        let x = c * (1 - abs(hPrime.truncatingRemainder(dividingBy: 2) - 1))

        var rp: CGFloat = 0
        var gp: CGFloat = 0
        var bp: CGFloat = 0

        switch hPrime {
        case 0..<1:
            rp = c; gp = x; bp = 0
        case 1..<2:
            rp = x; gp = c; bp = 0
        case 2..<3:
            rp = 0; gp = c; bp = x
        case 3..<4:
            rp = 0; gp = x; bp = c
        case 4..<5:
            rp = x; gp = 0; bp = c
        default:
            rp = c; gp = 0; bp = x
        }

        let m = targetL - c * 0.5
        return NSColor(
            calibratedRed: clamp(rp + m, min: 0, max: 1),
            green: clamp(gp + m, min: 0, max: 1),
            blue: clamp(bp + m, min: 0, max: 1),
            alpha: 1.0
        )
    }
}

private func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
    Swift.min(Swift.max(value, minValue), maxValue)
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

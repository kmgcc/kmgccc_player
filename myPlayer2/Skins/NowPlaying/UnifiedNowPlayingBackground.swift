//
//  UnifiedNowPlayingBackground.swift
//  myPlayer2
//
//  TrueMusic - Shared Now Playing Background
//  Static mesh gradient using artwork-derived colors.
//

import AppKit
import SwiftUI

struct UnifiedNowPlayingBackground: View {
    let context: SkinContext

    @State private var cachedTrackID: UUID?
    @State private var artworkPalette: [NSColor] = []

    var body: some View {
        Group {
            if #available(macOS 15.0, *) {
                MeshGradient(
                    width: 3,
                    height: 3,
                    points: Self.meshPoints,
                    colors: meshColors,
                    background: .clear,
                    smoothsColors: true
                )
            } else {
                LinearGradient(
                    colors: [meshColors[0], meshColors[4], meshColors[8]],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .overlay {
            Color.black.opacity(context.theme.colorScheme == .dark ? 0.20 : 0.06)
        }
        .ignoresSafeArea()
        .onAppear {
            refreshPaletteIfNeeded(force: true)
        }
        .onChange(of: context.track?.id) { _, _ in
            refreshPaletteIfNeeded(force: true)
        }
    }

    private var meshColors: [Color] {
        let palette = styledPalette()
        let c0 = palette[0]
        let c1 = palette[1]
        let c2 = palette[2]
        let c3 = palette[3]

        return [
            blend(c0, c1, 0.20),
            c1,
            blend(c1, c2, 0.35),
            c0,
            blend(c0, c2, 0.50),
            c2,
            blend(c3, c0, 0.40),
            blend(c2, c3, 0.45),
            c3,
        ]
    }

    private func refreshPaletteIfNeeded(force: Bool = false) {
        let trackID = context.track?.id
        if !force, cachedTrackID == trackID {
            return
        }
        cachedTrackID = trackID

        guard let data = context.track?.artworkData else {
            artworkPalette = []
            return
        }
        // Keep using the existing extractor algorithm unchanged.
        artworkPalette = ArtworkColorExtractor.uiThemePalette(from: data, maxColors: 4)
    }

    private func styledPalette() -> [Color] {
        let darkMode = context.theme.colorScheme == .dark
        var result = artworkPalette
            .compactMap { $0.usingColorSpace(.deviceRGB) }
            .map { style($0, darkMode: darkMode) }

        if result.count < 4 {
            let fallback = [
                NSColor(calibratedRed: 0.30, green: 0.45, blue: 0.58, alpha: 1.0),
                NSColor(calibratedRed: 0.50, green: 0.34, blue: 0.40, alpha: 1.0),
                NSColor(calibratedRed: 0.40, green: 0.52, blue: 0.34, alpha: 1.0),
                NSColor(calibratedRed: 0.58, green: 0.52, blue: 0.34, alpha: 1.0),
            ].map { style($0, darkMode: darkMode) }
            result.append(contentsOf: fallback)
        }
        return Array(result.prefix(4)).map { Color(nsColor: $0) }
    }

    private func style(_ color: NSColor, darkMode: Bool) -> NSColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let sat = clamp(saturation * (darkMode ? 0.92 : 0.80), min: 0.10, max: darkMode ? 0.82 : 0.62)
        let bri = clamp(
            darkMode ? brightness * 0.58 : brightness * 0.90,
            min: 0.10,
            max: darkMode ? 0.48 : 0.92
        )

        return NSColor(calibratedHue: hue, saturation: sat, brightness: bri, alpha: 1.0)
    }

    private func blend(_ a: Color, _ b: Color, _ t: CGFloat) -> Color {
        let ca = NSColor(a).usingColorSpace(.deviceRGB) ?? NSColor(a)
        let cb = NSColor(b).usingColorSpace(.deviceRGB) ?? NSColor(b)
        let tt = clamp(t, min: 0, max: 1)
        let r = ca.redComponent + (cb.redComponent - ca.redComponent) * tt
        let g = ca.greenComponent + (cb.greenComponent - ca.greenComponent) * tt
        let bl = ca.blueComponent + (cb.blueComponent - ca.blueComponent) * tt
        return Color(nsColor: NSColor(calibratedRed: r, green: g, blue: bl, alpha: 1.0))
    }

    private func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        Swift.min(maxValue, Swift.max(minValue, value))
    }

    @available(macOS 15.0, *)
    private static let meshPoints: [SIMD2<Float>] = [
        SIMD2<Float>(0.00, 0.00), SIMD2<Float>(0.50, 0.00), SIMD2<Float>(1.00, 0.00),
        SIMD2<Float>(0.00, 0.50), SIMD2<Float>(0.50, 0.50), SIMD2<Float>(1.00, 0.50),
        SIMD2<Float>(0.00, 1.00), SIMD2<Float>(0.50, 1.00), SIMD2<Float>(1.00, 1.00),
    ]
}

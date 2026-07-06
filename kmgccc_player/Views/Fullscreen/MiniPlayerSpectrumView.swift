//
//  MiniPlayerSpectrumView.swift
//  myPlayer2
//
//  kmgccc_player - MiniPlayer Spectrum Visualizer
//  Reuses PillSpectrumView from ClassicLEDSkin with parameterization.
//

import Foundation
import SwiftUI
import AppKit

/// Behavior when playback is paused
enum MiniPlayerSpectrumPausedBehavior {
    /// Use the default idle pattern from AudioVisualizationService (static decorative pattern)
    case `default`
    /// Shrink all pills to minimal dots (MiniPlayer exclusive)
    case minimalDots
}

/// Spectrum visualizer for MiniPlayer, reusing the existing PillSpectrumView.
/// Supports hover state animation: collapses to small dot/capsule and fades out.
/// Supports custom pause behavior: can shrink to minimal dots instead of showing static pattern.
@MainActor
struct MiniPlayerSpectrumView: View {
    let isPlaying: Bool
    let isActive: Bool
    let accentColor: Color?
    let artworkColors: [NSColor]
    let usesDarkForeground: Bool
    let scale: CGFloat
    let isHovered: Bool
    let pausedBehavior: MiniPlayerSpectrumPausedBehavior

    init(
        isPlaying: Bool,
        isActive: Bool = true,
        accentColor: Color?,
        artworkColors: [NSColor] = [],
        usesDarkForeground: Bool = false,
        scale: CGFloat,
        isHovered: Bool,
        pausedBehavior: MiniPlayerSpectrumPausedBehavior
    ) {
        self.isPlaying = isPlaying
        self.isActive = isActive
        self.accentColor = accentColor
        self.artworkColors = artworkColors
        self.usesDarkForeground = usesDarkForeground
        self.scale = scale
        self.isHovered = isHovered
        self.pausedBehavior = pausedBehavior
    }

    // Layout constants (scaled)
    private let baseDotSize: CGFloat = 5.8
    private let baseSpacing: CGFloat = 4
    private let baseHeight: CGFloat = 52
    private let baseWidth: CGFloat = 100
    private let collapsedWidth: CGFloat = 14
    private let baseCornerRadius: CGFloat = 10

    private var dotSize: CGFloat { baseDotSize * scale }
    private var spacing: CGFloat { baseSpacing * scale }
    private var height: CGFloat { baseHeight * scale }
    private var expandedWidth: CGFloat { baseWidth * scale }
    private var collapsedWidthScaled: CGFloat { collapsedWidth * scale }

    /// Current width based on hover state
    private var currentWidth: CGFloat {
        isHovered ? collapsedWidthScaled : expandedWidth
    }

    /// Current opacity based on hover state
    private var currentOpacity: Double {
        isHovered ? 0.0 : 1.0
    }

    /// Current corner radius based on hover state
    private var currentCornerRadius: CGFloat {
        isHovered ? collapsedWidthScaled * 0.5 : baseCornerRadius * scale
    }

    var body: some View {
        let resolvedAccent = Self.resolveStaticAccent(accentColor)
        MiniPlayerSpectrumContainer(
            isPlaying: isPlaying,
            isActive: isActive,
            accentColor: resolvedAccent,
            artworkColors: artworkColors,
            usesDarkForeground: usesDarkForeground,
            dotSize: dotSize,
            spacing: spacing,
            pausedBehavior: pausedBehavior
        )
        .frame(width: currentWidth, height: height)
        .opacity(currentOpacity)
        .clipShape(RoundedRectangle(cornerRadius: currentCornerRadius, style: .continuous))
        .animation(.spring(response: 0.35, dampingFraction: 0.75, blendDuration: 0.1), value: isHovered)
    }

    @MainActor
    private static func resolveStaticAccent(_ color: Color?) -> NSColor {
        let resolved = NSColor(color ?? AppSettings.shared.accentColor)
        let fallback = NSColor(AppSettings.shared.accentColor)
        let rgb = resolved.usingColorSpace(.deviceRGB)
            ?? fallback.usingColorSpace(.deviceRGB)
            ?? fallback
        return NSColor(
            red: rgb.redComponent,
            green: rgb.greenComponent,
            blue: rgb.blueComponent,
            alpha: 1.0
        )
    }
}

// MARK: - Container View

private struct MiniPlayerSpectrumContainer: NSViewRepresentable {
    let isPlaying: Bool
    let isActive: Bool
    let accentColor: NSColor
    let artworkColors: [NSColor]
    let usesDarkForeground: Bool
    let dotSize: CGFloat
    let spacing: CGFloat
    let pausedBehavior: MiniPlayerSpectrumPausedBehavior

    func makeNSView(context: Context) -> CapsuleSpectrumHostView {
        let view = CapsuleSpectrumHostView(configuration: makeConfiguration())
        applyColors(to: view)
        view.setActive(isActive)
        view.setPlayback(isPlaying: isPlaying)
        return view
    }

    func updateNSView(_ nsView: CapsuleSpectrumHostView, context: Context) {
        nsView.configure(makeConfiguration())
        applyColors(to: nsView)
        nsView.setActive(isActive)
        nsView.setPlayback(isPlaying: isPlaying)
    }

    static func dismantleNSView(_ nsView: CapsuleSpectrumHostView, coordinator: ()) {
        nsView.stop()
    }

    private func makeConfiguration() -> CapsuleSpectrumConfiguration {
        .centeredBars(
            capsuleWidth: dotSize,
            capsuleSpacing: spacing,
            strokeWidth: 0.5,
            pausedBehavior: pausedBehavior == .minimalDots ? .collapseToDots : .idlePose
        )
    }

    private func applyColors(to view: CapsuleSpectrumHostView) {
        let signature = SpectrumColorResolver.colorSignature(
            artworkColors: artworkColors,
            accentColor: accentColor,
            usesDarkForeground: usesDarkForeground
        )
        view.updateColors(signature: signature) {
            let resolved = SpectrumColorResolver.resolveArtworkFaithfulColors(
                from: artworkColors,
                fallback: accentColor,
                usesDarkForeground: usesDarkForeground
            )
            return (resolved.fillColors, resolved.strokeColors)
        }
    }
}

extension MiniPlayerSpectrumContainer: Equatable {
    static func == (lhs: MiniPlayerSpectrumContainer, rhs: MiniPlayerSpectrumContainer) -> Bool {
        lhs.isPlaying == rhs.isPlaying
            && lhs.isActive == rhs.isActive
            && lhs.dotSize == rhs.dotSize
            && lhs.spacing == rhs.spacing
            && lhs.pausedBehavior == rhs.pausedBehavior
            && lhs.accentColor.isVisuallyEqual(to: rhs.accentColor)
            && lhs.usesDarkForeground == rhs.usesDarkForeground
            && lhs.artworkColors.isVisuallyEqual(to: rhs.artworkColors)
    }
}

// MARK: - Host View

nonisolated enum SpectrumColorResolver {

    /// Fullscreen mini player spectrum colors that faithfully represent artwork palette.
    /// Preserves artwork hue/chroma with minimal adjustment for visibility against glass background.
    ///
    /// Callers pass `analysis.displayPalette.prefix(2)`. When the artwork is
    /// colour-thin (displayPalette has only 1 entry), avoid hue-rotated
    /// fabrication; instead derive the right endpoint as a same-hue OKLCH tonal
    /// variant of the single real colour. This keeps the L→R gradient quietly
    /// informative while staying honest about what the artwork contains.
    /// `lightModeDarkening` is the app *light* appearance (distinct from the
    /// artwork-driven `usesDarkForeground`): it darkens the fill so the bars read
    /// against a light glass, but gives the OUTLINE its own milder dark treatment
    /// (the bright-artwork path was too dark for this case).
    static func resolveArtworkFaithfulColors(
        from artworkColors: [NSColor],
        fallback accentColor: NSColor,
        usesDarkForeground: Bool,
        lightModeDarkening: Bool = false
    ) -> (fillColors: [CGColor], strokeColors: [CGColor]) {
        // Both reasons to darken the fill share the same brightness treatment.
        let darken = usesDarkForeground || lightModeDarkening
        let sources = Array(artworkColors.prefix(2))
        let leftSource = sources.first ?? accentColor
        let rightSource: NSColor = {
            if let explicit = sources.dropFirst().first {
                return explicit
            }
            // Single-colour path: build a same-hue L variant of the lone real
            // colour. No hue rotation. Falls back to accent only when even
            // OKLCH conversion fails.
            return makeTonalRightEndpoint(of: leftSource, usesDarkForeground: darken)
                ?? accentColor
        }()

        guard
            let leftBase = adjustedSpectrumBase(
                from: leftSource,
                usesDarkForeground: darken,
                alpha: 0.86
            ),
            let rightBase = adjustedSpectrumBase(
                from: rightSource,
                usesDarkForeground: darken,
                alpha: 0.80
            )
        else {
            return (Array(repeating: CGColor(gray: 0.6, alpha: 0.85), count: 9),
                    Array(repeating: CGColor(gray: 0.5, alpha: 0.7), count: 9))
        }

        let total = max(1, 9 - 1)
        var fillColors: [CGColor] = []
        var strokeColors: [CGColor] = []

        for index in 0..<9 {
            let t = CGFloat(index) / CGFloat(total)
            let r = leftBase.redComponent + (rightBase.redComponent - leftBase.redComponent) * t
            let g = leftBase.greenComponent + (rightBase.greenComponent - leftBase.greenComponent) * t
            let bComp = leftBase.blueComponent + (rightBase.blueComponent - leftBase.blueComponent) * t

            let fillAlpha = 0.85 - t * 0.08
            let fillColor = NSColor(calibratedRed: r, green: g, blue: bComp, alpha: fillAlpha)

            let strokeHSB = fillColor.usingColorSpace(.deviceRGB) ?? fillColor
            // Allowed legacy HSB residual: local graphic/rendering transform for outline stroke contrast.
            // Does not make semantic decisions. Output resolves via CGColor.
            var sh: CGFloat = 0, ss: CGFloat = 0, sb: CGFloat = 0, sa: CGFloat = 0
            strokeHSB.getHue(&sh, saturation: &ss, brightness: &sb, alpha: &sa)

            let strokeBri: CGFloat
            let strokeAlpha: CGFloat
            if lightModeDarkening {
                // App light mode: darker than the fill but kept readable — the
                // bright-artwork floor (0.12) was too dark for this case.
                strokeBri = min(0.52, max(0.30, sb - 0.05))
                strokeAlpha = 0.9
            } else if usesDarkForeground {
                // Bright artwork (e.g. big-cover MiniPlayer): unchanged.
                strokeBri = min(0.36, max(0.12, sb - 0.05))
                strokeAlpha = 0.78
            } else {
                strokeBri = min(1.0, max(0.58, sb + 0.08))
                strokeAlpha = 0.92
            }
            // Outline reads clearly more saturated than the fill. Multiplicative
            // so near-mono / grey covers stay neutral (no fabricated tint).
            let strokeSat = min(1.0, ss * 1.6)
            let strokeColor = NSColor(hue: sh, saturation: strokeSat, brightness: strokeBri, alpha: strokeAlpha)

            fillColors.append(ColorRenderingAdapter.makeCGColor(fillColor))
            strokeColors.append(ColorRenderingAdapter.makeCGColor(strokeColor))
        }

        return (fillColors, strokeColors)
    }

    /// Build a same-hue tonal right endpoint for the single-real-colour
    /// path. Used when only one displayPalette colour is available so the
    /// gradient still has some L→R differentiation without inventing hues.
    static func makeTonalRightEndpoint(
        of color: NSColor,
        usesDarkForeground: Bool
    ) -> NSColor? {
        guard let lch = OKColor.nsColorToOKLCH(color) else { return nil }
        // Push lightness one notch in the visibility direction; preserve hue
        // and chroma so the right end is recognisably the same colour as
        // the left, just lighter / darker.
        let lDelta: CGFloat = usesDarkForeground ? -0.10 : 0.10
        let newL = clamp01(lch.l + lDelta)
        let tuned = OKColor.OKLCH(l: newL, c: lch.c, h: lch.h)
        return OKColor.okLCHToNSColor(tuned, alpha: 1)
    }

    static func clamp01(_ value: CGFloat) -> CGFloat {
        min(1, max(0, value))
    }

    static func adjustedSpectrumBase(
        from color: NSColor,
        usesDarkForeground: Bool,
        alpha: CGFloat
    ) -> NSColor? {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return nil }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        let tunedSaturation: CGFloat
        if s > 0.72 {
            tunedSaturation = s * 0.88
        } else if s > 0.55 {
            tunedSaturation = s * 0.94
        } else if s < 0.06 {
            // Near-mono input must pass through. The legacy `max(0.18, s * 1.08)`
            // floor amplified residual hue from grey artwork into visible
            // pink/yellow tint. Caller has already OKLCH-neutralised near-mono
            // colours, but enforce the floor removal here too as defence in depth.
            tunedSaturation = s
        } else if s < 0.22 {
            // Low-saturation but not near-mono: preserve the artwork's muted
            // impression instead of lifting toward 0.18+ (which read as "more
            // colourful than the cover").
            tunedSaturation = min(0.30, s * 1.04)
        } else {
            tunedSaturation = min(0.70, max(0.18, s * 1.08))
        }

        let tunedBrightness: CGFloat
        if usesDarkForeground {
            tunedBrightness = min(0.42, max(0.18, b * 0.46))
        } else if b < 0.34 {
            tunedBrightness = min(0.92, b + 0.34)
        } else if b > 0.88 {
            tunedBrightness = max(0.70, b - 0.10)
        } else {
            tunedBrightness = min(0.94, max(0.58, b + 0.10))
        }

        return NSColor(
            hue: h,
            saturation: tunedSaturation,
            brightness: tunedBrightness,
            alpha: alpha
        )
    }

    // MARK: - Palette signature

    /// Stable hash of the artwork inputs so a host can skip the (OKLCH-heavy)
    /// color resolve when nothing visible changed. Shared by every spectrum
    /// surface that uses `resolveArtworkFaithfulColors`.
    static func colorSignature(
        artworkColors: [NSColor],
        accentColor: NSColor,
        usesDarkForeground: Bool,
        lightModeDarkening: Bool = false
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(usesDarkForeground)
        hasher.combine(lightModeDarkening)
        for color in artworkColors.prefix(2) { appendColor(color, to: &hasher) }
        appendColor(accentColor, to: &hasher)
        return hasher.finalize()
    }

    private static func appendColor(_ color: NSColor, to hasher: inout Hasher) {
        let resolved = color.usingColorSpace(.deviceRGB) ?? color
        hasher.combine(Int(resolved.redComponent * 1_000))
        hasher.combine(Int(resolved.greenComponent * 1_000))
        hasher.combine(Int(resolved.blueComponent * 1_000))
        hasher.combine(Int(resolved.alphaComponent * 1_000))
    }

    // MARK: - Palette preparation

    static func prepareSpectrumColors(
        _ colors: [NSColor],
        analysis: ArtworkColorAnalysis
    ) -> [NSColor] {
        guard !colors.isEmpty else { return colors }
        if analysis.isNearMonochrome && !analysis.hasTrustedHueCandidate {
            return colors.map { neutralizeForNearMono($0) ?? $0 }
        }
        if analysis.colorfulness < 0.18 {
            return colors.map { dampenLowSaturation($0) ?? $0 }
        }
        return colors
    }

    /// Force a near-monochrome source to perceptual grey: preserve L,
    /// crush chroma to ~0 in OKLCH. Guarantees no visible hue tint
    /// regardless of which salient highlight the displayPalette surfaced.
    static func neutralizeForNearMono(_ color: NSColor) -> NSColor? {
        guard let lch = OKColor.nsColorToOKLCH(color) else { return nil }
        let neutral = OKColor.OKLCH(l: lch.l, c: min(lch.c, 0.008), h: lch.h)
        return OKColor.okLCHToNSColor(neutral, alpha: 1)
    }

    /// Soft-clamp chroma on low-saturation (but not near-mono) covers so
    /// downstream visibility tuning doesn't lift them above their natural
    /// muted impression.
    static func dampenLowSaturation(_ color: NSColor) -> NSColor? {
        guard let lch = OKColor.nsColorToOKLCH(color) else { return nil }
        let shouldered = OKColor.chromaSoftShoulder(lch, ceiling: 0.05, softness: 0.04)
        return OKColor.okLCHToNSColor(shouldered, alpha: 1)
    }
}

private extension NSColor {
    func isVisuallyEqual(to other: NSColor) -> Bool {
        guard
            let lhs = usingColorSpace(.deviceRGB),
            let rhs = other.usingColorSpace(.deviceRGB)
        else {
            return false
        }

        let epsilon: CGFloat = 0.001
        return abs(lhs.redComponent - rhs.redComponent) < epsilon
            && abs(lhs.greenComponent - rhs.greenComponent) < epsilon
            && abs(lhs.blueComponent - rhs.blueComponent) < epsilon
            && abs(lhs.alphaComponent - rhs.alphaComponent) < epsilon
    }
}

private extension Array where Element == NSColor {
    func isVisuallyEqual(to other: [NSColor]) -> Bool {
        guard count == other.count else { return false }
        return zip(self, other).allSatisfy { lhs, rhs in
            lhs.isVisuallyEqual(to: rhs)
        }
    }
}

// MARK: - Preview

#Preview("MiniPlayer Spectrum") { @MainActor in
    VStack(spacing: 20) {
        HStack(spacing: 20) {
            // Normal state - playing
            MiniPlayerSpectrumView(
                isPlaying: true,
                accentColor: .blue,
                scale: 1.0,
                isHovered: false,
                pausedBehavior: .minimalDots
            )
            .frame(width: 100, height: 52)
            .background(Color.black.opacity(0.1))
            .cornerRadius(10)

            // Hovered state
            MiniPlayerSpectrumView(
                isPlaying: true,
                accentColor: .blue,
                scale: 1.0,
                isHovered: true,
                pausedBehavior: .minimalDots
            )
            .frame(width: 14, height: 52)
            .background(Color.black.opacity(0.1))
            .cornerRadius(7)
            
            // Paused state with minimal dots
            MiniPlayerSpectrumView(
                isPlaying: false,
                accentColor: .blue,
                scale: 1.0,
                isHovered: false,
                pausedBehavior: .minimalDots
            )
            .frame(width: 100, height: 52)
            .background(Color.black.opacity(0.1))
            .cornerRadius(10)
        }
    }
    .padding(40)
}

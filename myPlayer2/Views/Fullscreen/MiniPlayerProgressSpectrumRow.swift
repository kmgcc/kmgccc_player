//
//  MiniPlayerProgressSpectrumRow.swift
//  myPlayer2
//
//  kmgccc_player - Unified progress bar + spectrum row with single hover state
//  Fixes hover fragmentation, state jitter, and hit-testing issues.
//

import Foundation
import SwiftUI

/// Unified row containing progress bar and optional spectrum visualizer.
/// Uses a single hover state source to drive both components' animations.
/// When hovered: spectrum collapses to minimum width + fades out, progress bar expands to fill.
/// When not hovered: spectrum expands to full width + fades in, progress bar contracts to make room.
@MainActor
struct MiniPlayerProgressSpectrumRow: View {
    let scale: CGFloat
    let isSpectrumEnabled: Bool
    let isPlaying: Bool
    let accentColor: Color?
    
    // Progress bar state
    let progress: Double
    let duration: Double
    let onSeek: (Double) -> Void
    let onDragStart: () -> Void
    let onDragEnd: () -> Void
    let onInteraction: () -> Void
    let onDragStateChanged: (Bool) -> Void
    
    // Layout constants
    private var spectrumExpandedWidth: CGFloat { 100 * scale }
    private var spectrumCollapsedWidth: CGFloat { 14 * scale }
    private var spectrumHeight: CGFloat { 52 * scale }
    private var barHeight: CGFloat { 6 * scale }
    private var timeFontSize: CGFloat { 10.5 * scale }
    private var progressYOffset: CGFloat { 13 * scale }
    private var hPadding: CGFloat { 8 * scale }
    private var timeSpacing: CGFloat { 10 * scale }
    
    /// Unified hover state for the entire row
    @State private var isRowHovered = false

    init(
        scale: CGFloat,
        isSpectrumEnabled: Bool,
        isPlaying: Bool,
        accentColor: Color?,
        progress: Double,
        duration: Double,
        onSeek: @escaping (Double) -> Void,
        onDragStart: @escaping () -> Void,
        onDragEnd: @escaping () -> Void,
        onInteraction: @escaping () -> Void = {},
        onDragStateChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.scale = scale
        self.isSpectrumEnabled = isSpectrumEnabled
        self.isPlaying = isPlaying
        self.accentColor = accentColor
        self.progress = progress
        self.duration = duration
        self.onSeek = onSeek
        self.onDragStart = onDragStart
        self.onDragEnd = onDragEnd
        self.onInteraction = onInteraction
        self.onDragStateChanged = onDragStateChanged
    }
    
    var body: some View {
        // Single unified hover region covering the entire progress+spectrum area
        HStack(spacing: 2 * scale) {
            // Progress bar section - expands when spectrum collapses
            progressBarSection
                .layoutPriority(isRowHovered && isSpectrumEnabled ? 1 : 0)
            
            // Spectrum section - only if enabled
            if isSpectrumEnabled {
                spectrumSection
            }
        }
        .frame(maxHeight: .infinity)
        // CRITICAL: Single hover handler for the entire row
        .onHover { hovering in
            isRowHovered = hovering
            if hovering {
                onInteraction()
            }
        }
    }
    
    // MARK: - Progress Bar Section
    
    private var progressBarSection: some View {
        ZStack {
            // The actual progress bar
            GeometryReader { geometry in
                let filledWidth = progressWidth(in: geometry.size.width)
                
                ZStack(alignment: .leading) {
                    // Track - full width capsule
                    Capsule()
                        .fill(progressTrackColor)
                        .frame(height: barHeight)
                    
                    // Fill - always a full capsule, masked to filled width
                    Capsule()
                        .fill(progressFillColor)
                        .frame(height: barHeight)
                        .mask(
                            Rectangle()
                                .frame(width: max(barHeight, filledWidth))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, 2 * scale)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            onInteraction()
                            onDragStart()
                            onDragStateChanged(true)
                            let progress = max(0, min(1, value.location.x / geometry.size.width))
                            onSeek(progress * duration)
                        }
                        .onEnded { value in
                            onInteraction()
                            let progress = max(0, min(1, value.location.x / geometry.size.width))
                            onSeek(progress * duration)
                            onDragEnd()
                            onDragStateChanged(false)
                        }
                )
            }
            
            // Time labels overlay - show only on hover
            HStack(spacing: timeSpacing) {
                NumericTimeText(
                    time: progress,
                    fontSize: timeFontSize,
                    fontWeight: .medium,
                    color: timeColor
                )
                
                Spacer(minLength: 18 * scale)
                
                NumericTimeText(
                    time: duration,
                    fontSize: timeFontSize,
                    fontWeight: .medium,
                    color: timeColor
                )
            }
            .padding(.horizontal, hPadding)
            .offset(y: progressYOffset)
            .opacity(isRowHovered ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: isRowHovered)
        }
        .frame(maxHeight: .infinity)
        .padding(.horizontal, hPadding)
        .animation(.spring(response: 0.35, dampingFraction: 0.75, blendDuration: 0.1), value: isRowHovered)
    }
    
    // MARK: - Spectrum Section
    
    private var spectrumSection: some View {
        MiniPlayerSpectrumView(
            isPlaying: isPlaying,
            accentColor: accentColor,
            scale: scale,
            isHovered: isRowHovered,
            pausedBehavior: .minimalDots
        )
        // Width animates between expanded and collapsed
        .frame(width: isRowHovered ? spectrumCollapsedWidth : spectrumExpandedWidth, height: spectrumHeight)
        // Opacity fades out when collapsed
        .opacity(isRowHovered ? 0 : 1)
        // CRITICAL: Disable hit testing when collapsed/hidden to not block progress bar
        .allowsHitTesting(!isRowHovered)
        // Single animation for all properties
        .animation(.spring(response: 0.35, dampingFraction: 0.75, blendDuration: 0.1), value: isRowHovered)
    }
    
    // MARK: - Color Helpers

    /// Minimum lightness for progress/time colors (80% HSL)
    private static let minLightness: CGFloat = 0.80

    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        let p = progress / duration
        return totalWidth * CGFloat(max(0, min(1, p)))
    }

    private var progressFillColor: Color {
        let base = accentColor ?? Color.primary
        return enforceMinLightness(base, minLightness: Self.minLightness).opacity(0.9)
    }

    private var progressTrackColor: Color {
        let base = accentColor ?? Color.secondary
        return enforceMinLightness(base, minLightness: Self.minLightness).opacity(0.25)
    }

    private var timeColor: Color {
        let base = accentColor ?? Color.primary
        return enforceMinLightness(base, minLightness: Self.minLightness)
    }

    // MARK: - HSL Color Processing

    private func enforceMinLightness(_ color: Color, minLightness: CGFloat) -> Color {
        let nsColor = NSColor(color)
        guard let hsl = hslComponents(from: nsColor) else { return color }
        let targetL = max(hsl.l, minLightness)
        if targetL <= hsl.l + 0.000_001 { return color }
        let adjustedNSColor = rgbColorFromHsl(h: hsl.h, s: hsl.s, l: targetL)
        return Color(nsColor: adjustedNSColor)
    }

    private func hslComponents(from color: NSColor) -> (h: CGFloat, s: CGFloat, l: CGFloat)? {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return nil }

        let r = clamp01(rgb.redComponent)
        let g = clamp01(rgb.greenComponent)
        let b = clamp01(rgb.blueComponent)

        let maxV = max(r, max(g, b))
        let minV = min(r, min(g, b))
        let delta = maxV - minV
        let l = (maxV + minV) * 0.5

        var h: CGFloat = 0
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

        return (h: h, s: s, l: l)
    }

    private func rgbColorFromHsl(h: CGFloat, s: CGFloat, l: CGFloat) -> NSColor {
        let c = (1 - abs(2 * l - 1)) * s
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

        let m = l - c * 0.5
        return NSColor(
            calibratedRed: clamp01(rp + m),
            green: clamp01(gp + m),
            blue: clamp01(bp + m),
            alpha: 1.0
        )
    }

    private func clamp01(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}

// MARK: - Preview

#Preview("Progress + Spectrum Row") { @MainActor in
    VStack(spacing: 40) {
        // With spectrum
        MiniPlayerProgressSpectrumRow(
            scale: 1.0,
            isSpectrumEnabled: true,
            isPlaying: true,
            accentColor: .blue,
            progress: 45,
            duration: 180,
            onSeek: { _ in },
            onDragStart: {},
            onDragEnd: {}
        )
        .frame(height: 60)
        .background(Color.gray.opacity(0.1))
        
        // Without spectrum
        MiniPlayerProgressSpectrumRow(
            scale: 1.0,
            isSpectrumEnabled: false,
            isPlaying: true,
            accentColor: .blue,
            progress: 45,
            duration: 180,
            onSeek: { _ in },
            onDragStart: {},
            onDragEnd: {}
        )
        .frame(height: 60)
        .background(Color.gray.opacity(0.1))
    }
    .padding(40)
    .frame(width: 800)
}

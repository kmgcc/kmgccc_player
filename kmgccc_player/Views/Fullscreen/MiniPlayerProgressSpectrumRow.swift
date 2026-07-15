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
    let visualization: AudioVisualizationKind
    let isPlaying: Bool
    let isSpectrumActive: Bool
    let accentColor: Color?
    let foregroundColor: Color?
    let foregroundProfile: FullscreenMiniPlayerForegroundProfile?
    let enforceBrightForeground: Bool
    let spectrumArtworkColors: [NSColor]
    let spectrumUsesDarkForeground: Bool
    let ledToneVariant: PerceptualToneLadder.LEDToneVariant
    let adaptsWideVisualizationSegments: Bool
    let usesVisualizationAsCompactProgress: Bool
    
    // Progress bar state
    let progress: Double
    let duration: Double
    let isSeekEnabled: Bool
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
    private var timeFontSize: CGFloat { 11.5 * scale }
    private var progressYOffset: CGFloat { 13 * scale }
    private var hPadding: CGFloat { 8 * scale }
    private var timeSpacing: CGFloat { 10 * scale }
    private var compactSpectrumTimeBottomInset: CGFloat { 2 * scale }
    private var compactSpectrumLabelCutoutWidth: CGFloat {
        max(28 * scale, timeFontSize * 3.4)
    }
    private var compactSpectrumLabelCutoutHeight: CGFloat {
        max(18 * scale, timeFontSize + 6 * scale)
    }
    private var compactSpectrumLabelCutoutFeather: CGFloat { 3 * scale }
    // A window row should not gain extra dots while it is still in its normal
    // compact range; once it is genuinely wide, grow the right-hand visualizer
    // so the progress track does not consume empty space.
    private var baseVisualizationCount: Int { visualization == .led ? 5 : 9 }
    private var wideVisualizationStartWidth: CGFloat { max(260, 300 * scale) }
    private var spectrumWideSegmentStartWidth: CGFloat { max(340, 420 * scale) }
    private var wideVisualizationMaximumWidth: CGFloat {
        max(spectrumExpandedWidth, 220 * scale)
    }
    
    /// Unified hover state for the entire row
    @State private var isRowHovered = false

    init(
        scale: CGFloat,
        visualization: AudioVisualizationKind,
        isPlaying: Bool,
        isSpectrumActive: Bool = true,
        accentColor: Color?,
        foregroundColor: Color? = nil,
        foregroundProfile: FullscreenMiniPlayerForegroundProfile? = nil,
        enforceBrightForeground: Bool = true,
        spectrumArtworkColors: [NSColor] = [],
        spectrumUsesDarkForeground: Bool = false,
        ledToneVariant: PerceptualToneLadder.LEDToneVariant = .retuned,
        adaptsWideVisualizationSegments: Bool = false,
        usesVisualizationAsCompactProgress: Bool = false,
        progress: Double,
        duration: Double,
        isSeekEnabled: Bool = true,
        onSeek: @escaping (Double) -> Void,
        onDragStart: @escaping () -> Void,
        onDragEnd: @escaping () -> Void,
        onInteraction: @escaping () -> Void = {},
        onDragStateChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.scale = scale
        self.visualization = visualization
        self.isPlaying = isPlaying
        self.isSpectrumActive = isSpectrumActive
        self.accentColor = accentColor
        self.foregroundColor = foregroundColor
        self.foregroundProfile = foregroundProfile
        self.enforceBrightForeground = enforceBrightForeground
        self.spectrumArtworkColors = spectrumArtworkColors
        self.spectrumUsesDarkForeground = spectrumUsesDarkForeground
        self.ledToneVariant = ledToneVariant
        self.adaptsWideVisualizationSegments = adaptsWideVisualizationSegments
        self.usesVisualizationAsCompactProgress = usesVisualizationAsCompactProgress
        self.progress = progress
        self.duration = duration
        self.isSeekEnabled = isSeekEnabled
        self.onSeek = onSeek
        self.onDragStart = onDragStart
        self.onDragEnd = onDragEnd
        self.onInteraction = onInteraction
        self.onDragStateChanged = onDragStateChanged
    }
    
    var body: some View {
        GeometryReader { geometry in
            if usesVisualizationAsCompactProgress,
               visualization != .off,
               geometry.size.width < 170 {
                compactVisualizationProgress(size: geometry.size)
            } else {
                HStack(alignment: .center, spacing: 2 * scale) {
                    progressBarSection
                        .layoutPriority(isRowHovered && visualization != .off ? 1 : 0)

                    if visualization != .off {
                        visualizationSection(
                            availableWidth: geometry.size.width,
                            availableHeight: geometry.size.height
                        )
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
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
                        .isolatesFullscreenBottomControlRenderingFromGeometryAnimation()
                        .frame(height: barHeight)
                    
                    // Fill - always a full capsule, masked to filled width
                    Capsule()
                        .fill(progressFillColor)
                        .isolatesFullscreenBottomControlRenderingFromGeometryAnimation()
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
                            guard isSeekEnabled else { return }
                            onInteraction()
                            onDragStart()
                            onDragStateChanged(true)
                            let progress = max(0, min(1, value.location.x / geometry.size.width))
                            onSeek(progress * duration)
                        }
                        .onEnded { value in
                            guard isSeekEnabled else {
                                onDragStateChanged(false)
                                return
                            }
                            onInteraction()
                            let progress = max(0, min(1, value.location.x / geometry.size.width))
                            onSeek(progress * duration)
                            onDragEnd()
                            onDragStateChanged(false)
                        }
                )
            }
            
            timeLabels
        }
        .frame(maxHeight: .infinity)
        .padding(.horizontal, hPadding)
        .animation(.spring(response: 0.35, dampingFraction: 0.75, blendDuration: 0.1), value: isRowHovered)
    }
    
    // MARK: - Spectrum Section
    
    private func visualizationSection(availableWidth: CGFloat, availableHeight: CGFloat) -> some View {
        let height = min(spectrumHeight, availableHeight)
        let expandedWidth = resolvedVisualizationWidth(for: availableWidth)
        let count: Int
        if visualization == .spectrum {
            count = wideSpectrumSegmentCount(
                availableWidth: availableWidth,
                renderedWidth: expandedWidth
            )
        } else {
            let shouldAdaptWideSegments = adaptsWideVisualizationSegments
                && availableWidth > wideVisualizationStartWidth
            count = shouldAdaptWideSegments
                ? max(baseVisualizationCount, adaptiveSegmentCount(for: expandedWidth))
                : baseVisualizationCount
        }
        return visualizationContent(
            count: count,
            width: expandedWidth,
            height: height
        )
        .isolatesFullscreenBottomControlRenderingFromGeometryAnimation()
        .frame(width: isRowHovered ? spectrumCollapsedWidth : expandedWidth, height: height)
        .frame(maxHeight: .infinity, alignment: .center)
        .opacity(isRowHovered ? 0 : 1)
        .allowsHitTesting(!isRowHovered)
        .animation(.spring(response: 0.35, dampingFraction: 0.75, blendDuration: 0.1), value: isRowHovered)
    }

    private func compactVisualizationProgress(size: CGSize) -> some View {
        let count = visualization == .spectrum
            ? compactSpectrumSegmentCount(for: size.width)
            : adaptiveSegmentCount(for: size.width)
        let filledWidth = progressWidth(in: size.width)
        let contentHeight = min(spectrumHeight, size.height)
        return ZStack {
            visualizationContent(count: count, width: size.width, height: contentHeight)
                .isolatesFullscreenBottomControlRenderingFromGeometryAnimation()
                .opacity(0.30)
                .mask {
                    compactVisualizationLabelMask(size: size)
                }

            visualizationContent(count: count, width: size.width, height: contentHeight)
                .isolatesFullscreenBottomControlRenderingFromGeometryAnimation()
                .mask(alignment: .leading) {
                    compactProgressMask(filledWidth: filledWidth)
                }
                .mask {
                    compactVisualizationLabelMask(size: size)
                }

            compactVisualizationTimeLabels
                .zIndex(1)
        }
        .frame(width: size.width, height: size.height, alignment: .center)
        .clipped()
        .contentShape(Rectangle())
        .gesture(seekGesture(width: size.width))
    }

    @ViewBuilder
    private var compactVisualizationTimeLabels: some View {
        switch visualization {
        case .spectrum:
            compactSpectrumTimeLabels
        case .led:
            timeLabels.offset(y: 2 * scale)
        case .off:
            EmptyView()
        }
    }

    private var compactSpectrumTimeLabels: some View {
        HStack(alignment: .bottom, spacing: 0) {
            numericTimeLabel(time: progress)

            Spacer(minLength: 0)

            numericTimeLabel(time: duration)
        }
        .padding(.horizontal, hPadding)
        .padding(.bottom, compactSpectrumTimeBottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .opacity(isRowHovered ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: isRowHovered)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func compactVisualizationLabelMask(size: CGSize) -> some View {
        ZStack {
            Rectangle()
                .fill(.white)

            if visualization == .spectrum {
                HStack(alignment: .bottom, spacing: 0) {
                    spectrumLabelCutout
                        .padding(.leading, hPadding)
                        .padding(.bottom, compactSpectrumTimeBottomInset)

                    Spacer(minLength: 0)

                    spectrumLabelCutout
                        .padding(.trailing, hPadding)
                        .padding(.bottom, compactSpectrumTimeBottomInset)
                }
                .frame(width: size.width, height: size.height, alignment: .bottom)
                .opacity(isRowHovered ? 1 : 0)
            }
        }
        .compositingGroup()
        .frame(width: size.width, height: size.height)
        .animation(.easeInOut(duration: 0.2), value: isRowHovered)
    }

    private var spectrumLabelCutout: some View {
        RoundedRectangle(
            cornerRadius: compactSpectrumLabelCutoutHeight * 0.28,
            style: .continuous
        )
        .fill(.black)
        .frame(
            width: compactSpectrumLabelCutoutWidth,
            height: compactSpectrumLabelCutoutHeight
        )
        .blur(radius: compactSpectrumLabelCutoutFeather)
        .blendMode(.destinationOut)
    }

    private func numericTimeLabel(time: Double) -> some View {
        NumericTimeText(
            time: time,
            fontSize: timeFontSize,
            fontWeight: .medium,
            color: timeColor
        )
        .isolatesFullscreenBottomControlRenderingFromGeometryAnimation()
    }

    private var timeLabels: some View {
        HStack(spacing: timeSpacing) {
            numericTimeLabel(time: progress)

            Spacer(minLength: 18 * scale)

            numericTimeLabel(time: duration)
        }
        .padding(.horizontal, hPadding)
        .offset(y: progressYOffset)
        .opacity(isRowHovered ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: isRowHovered)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func visualizationContent(count: Int, width: CGFloat, height: CGFloat) -> some View {
        switch visualization {
        case .off:
            EmptyView()
        case .spectrum:
            MiniPlayerSpectrumView(
                isPlaying: isPlaying,
                isActive: isSpectrumActive,
                accentColor: spectrumFallbackColor,
                artworkColors: spectrumArtworkColors,
                usesDarkForeground: resolvedSpectrumUsesDarkForeground,
                scale: scale,
                isHovered: false,
                pausedBehavior: .minimalDots,
                capsuleCount: count,
                preferredWidth: width,
                preferredHeight: height
            )
        case .led:
            LiveLedMeterView(
                dotSize: 10 * scale,
                spacing: 6 * scale,
                pillTint: nil,
                isPlaying: isPlaying,
                forceBrightLEDColors: false,
                colorSchemeOverride: ledToneVariant == .appleStyleBright
                    ? .dark
                    : (resolvedLEDUsesDarkForeground ? .light : .dark),
                levelToneVariant: ledToneVariant,
                ledCountOverride: count,
                showsStatusLight: true,
                overlaysStatusLightOnFirstLED: true,
                fillDirection: .leftToRight,
                drawsPill: false,
                horizontalPadding: 0,
                verticalPadding: 0
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func adaptiveSegmentCount(for width: CGFloat) -> Int {
        let elementWidth = visualization == .led ? 10 * scale : 5.8 * scale
        let spacing = visualization == .led ? 6 * scale : 4 * scale
        return max(3, Int((width + spacing) / (elementWidth + spacing)))
    }

    private func compactSpectrumSegmentCount(for width: CGFloat) -> Int {
        max(5, adaptiveSegmentCount(for: width))
    }

    private func wideSpectrumSegmentCount(
        availableWidth: CGFloat,
        renderedWidth: CGFloat
    ) -> Int {
        guard adaptsWideVisualizationSegments,
              availableWidth > spectrumWideSegmentStartWidth
        else {
            return 9
        }

        // Once the spectrum is allowed to grow, derive the count from its
        // actual rendered width. The centered-bars layout otherwise leaves a
        // large symmetric gap when the frame grows faster than the nine-bar
        // baseline can fill it.
        return max(9, adaptiveSegmentCount(for: renderedWidth))
    }

    @ViewBuilder
    private func compactProgressMask(filledWidth: CGFloat) -> some View {
        Group {
            if isRowHovered {
                Rectangle()
                    .fill(.white)
                    .frame(width: filledWidth)
            } else {
                let featherWidth = min(filledWidth, max(10, 18 * scale))
                let solidWidth = max(0, filledWidth - featherWidth)
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(.white)
                        .frame(width: solidWidth)

                    LinearGradient(
                        colors: [.white, .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: featherWidth)
                }
            }
        }
        .frame(width: filledWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func resolvedVisualizationWidth(for availableWidth: CGFloat) -> CGFloat {
        guard adaptsWideVisualizationSegments else { return spectrumExpandedWidth }
        let growthStartWidth = visualization == .spectrum
            ? spectrumWideSegmentStartWidth
            : wideVisualizationStartWidth
        let extraWidth = max(0, availableWidth - growthStartWidth)
        let grownWidth = spectrumExpandedWidth + extraWidth * 0.38
        return min(wideVisualizationMaximumWidth, grownWidth)
    }

    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isSeekEnabled else { return }
                onInteraction()
                onDragStart()
                onDragStateChanged(true)
                onSeek(max(0, min(1, value.location.x / width)) * duration)
            }
            .onEnded { value in
                guard isSeekEnabled else {
                    onDragStateChanged(false)
                    return
                }
                onSeek(max(0, min(1, value.location.x / width)) * duration)
                onDragEnd()
                onDragStateChanged(false)
            }
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
        let base = resolvedForegroundColor
        let resolved = resolvedEnforceBrightForeground
            ? enforceMinLightness(base, minLightness: Self.minLightness)
            : base
        return resolved.opacity(isSeekEnabled ? 0.9 : 0.5)
    }

    private var progressTrackColor: Color {
        let base = resolvedForegroundColor
        let resolved = resolvedEnforceBrightForeground
            ? enforceMinLightness(base, minLightness: Self.minLightness)
            : base
        return resolved.opacity(0.25)
    }

    private var timeColor: Color {
        let base = resolvedForegroundColor
        return resolvedEnforceBrightForeground
            ? enforceMinLightness(base, minLightness: Self.minLightness)
            : base
    }

    private var resolvedForegroundColor: Color {
        if let foregroundProfile {
            return foregroundProfile.primaryColor.opacity(0.96)
        }
        return foregroundColor ?? accentColor ?? Color.primary
    }

    private var spectrumFallbackColor: Color? {
        if let foregroundProfile {
            return foregroundProfile.primaryColor
        }
        return foregroundColor ?? accentColor
    }

    private var resolvedEnforceBrightForeground: Bool {
        foregroundProfile?.enforceBrightProgressForeground ?? enforceBrightForeground
    }

    private var resolvedSpectrumUsesDarkForeground: Bool {
        foregroundProfile?.spectrumUsesDarkForeground ?? spectrumUsesDarkForeground
    }

    private var resolvedLEDUsesDarkForeground: Bool {
        foregroundProfile?.isDarkForeground ?? resolvedSpectrumUsesDarkForeground
    }

    // MARK: - HSL Color Processing

    private func enforceMinLightness(_ color: Color, minLightness: CGFloat) -> Color {
        let nsColor = NSColor(color)
        guard let hsl = hslComponents(from: nsColor) else { return color }
        let targetL = max(hsl.l, minLightness)
        if targetL <= hsl.l + 0.000_001 { return color }
        let adjustedNSColor = rgbColorFromHsl(h: hsl.h, s: hsl.s, l: targetL)
        return ColorRenderingAdapter.makeSwiftUIColor(adjustedNSColor)
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
            visualization: .spectrum,
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
            visualization: .off,
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

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
    let accentColor: Color?
    let scale: CGFloat
    let isHovered: Bool
    let pausedBehavior: MiniPlayerSpectrumPausedBehavior

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
            accentColor: resolvedAccent,
            dotSize: dotSize,
            spacing: spacing,
            pausedBehavior: pausedBehavior
        )
        .frame(width: currentWidth, height: height)
        .opacity(currentOpacity)
        .clipShape(RoundedRectangle(cornerRadius: currentCornerRadius, style: .continuous))
        .animation(.spring(response: 0.35, dampingFraction: 0.75, blendDuration: 0.1), value: isHovered)
    }

    private static func resolveStaticAccent(_ color: Color?) -> NSColor {
        guard let swiftUIColor = color else { return NSColor(white: 0.7, alpha: 1.0) }
        let resolved = NSColor(swiftUIColor)
        guard let rgb = resolved.usingColorSpace(.deviceRGB) else {
            return NSColor(white: 0.7, alpha: 1.0)
        }
        return NSColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: 1.0)
    }
}

// MARK: - Container View

private struct MiniPlayerSpectrumContainer: NSViewRepresentable {
    let isPlaying: Bool
    let accentColor: NSColor
    let dotSize: CGFloat
    let spacing: CGFloat
    let pausedBehavior: MiniPlayerSpectrumPausedBehavior

    func makeNSView(context: Context) -> MiniPlayerSpectrumHostView {
        let view = MiniPlayerSpectrumHostView()
        view.dotSize = dotSize
        view.spacing = spacing
        view.pausedBehavior = pausedBehavior
        view.updateAccentColor(accentColor)
        view.start()
        view.setPlayback(isPlaying: isPlaying)
        return view
    }

    func updateNSView(_ nsView: MiniPlayerSpectrumHostView, context: Context) {
        nsView.dotSize = dotSize
        nsView.spacing = spacing
        nsView.pausedBehavior = pausedBehavior
        nsView.updateAccentColor(accentColor)
        nsView.setPlayback(isPlaying: isPlaying)
    }

    static func dismantleNSView(_ nsView: MiniPlayerSpectrumHostView, coordinator: ()) {
        nsView.stop()
    }
}

// MARK: - Host View

@MainActor
private final class MiniPlayerSpectrumHostView: NSView {
    private let service = AudioVisualizationService.shared
    private let rootLayer = CALayer()
    private var capsuleLayers: [CALayer] = []
    private var strokeLayers: [CAShapeLayer] = []
    private var consumerID: UUID?

    private var currentWave = Array(repeating: Float(0), count: 9)
    private var frozenWave: [Float]? // Frozen wave values for pause animation
    private var cachedColors: [CGColor] = []
    private var cachedStrokeColors: [CGColor] = []
    private var lastPlaybackState: Bool?
    private var lastLayoutSize: CGSize = .zero
    
    // Pause behavior configuration
    var pausedBehavior: MiniPlayerSpectrumPausedBehavior = .default
    private var isCurrentlyPlaying: Bool = false
    private var pauseTransitionProgress: CGFloat = 0.0
    private var pauseTransitionTimer: Timer?

    var dotSize: CGFloat = 6
    var spacing: CGFloat = 5

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false

        rootLayer.masksToBounds = false
        layer?.addSublayer(rootLayer)
        setupCapsuleLayers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        guard bounds.size != lastLayoutSize else { return }
        lastLayoutSize = bounds.size
        layoutCapsules()
    }

    func start() {
        guard consumerID == nil else { return }
        service.start()
        consumerID = service.addConsumer { [weak self] wave in
            self?.applyWave(wave)
        }
    }

    func stop() {
        if let consumerID {
            service.removeConsumer(consumerID)
            self.consumerID = nil
        }
        pauseTransitionTimer?.invalidate()
        pauseTransitionTimer = nil
        currentWave = Array(repeating: 0, count: 9)
        layoutCapsules()
    }

    func setPlayback(isPlaying: Bool) {
        guard lastPlaybackState != isPlaying else { return }
        lastPlaybackState = isPlaying
        isCurrentlyPlaying = isPlaying
        service.updatePlaybackState(isPlaying: isPlaying)
        
        if pausedBehavior == .minimalDots {
            if !isPlaying {
                frozenWave = currentWave
            } else {
                frozenWave = nil
            }
            startPauseTransitionAnimation()
        }
    }
    
    /// Animates the transition between playing and paused states
    private func startPauseTransitionAnimation() {
        pauseTransitionTimer?.invalidate()
        
        let targetProgress: CGFloat = isCurrentlyPlaying ? 0.0 : 1.0
        let step: CGFloat = 0.08 // Animation speed
        
        // Timer fires on main thread (scheduled on main RunLoop), safe to assume isolated
        pauseTransitionTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.tickPauseTransition(targetProgress: targetProgress, step: step)
            }
        }
    }
    
    @MainActor
    private func tickPauseTransition(targetProgress: CGFloat, step: CGFloat) {
        let diff = targetProgress - pauseTransitionProgress
        if abs(diff) < 0.01 {
            pauseTransitionProgress = targetProgress
            layoutCapsules()
            pauseTransitionTimer?.invalidate()
            pauseTransitionTimer = nil
        } else {
            pauseTransitionProgress += diff * step
            layoutCapsules()
        }
    }

    func updateAccentColor(_ accentColor: NSColor) {
        let resolved = Self.resolveStaticLightModeColors(from: accentColor)
        cachedColors = resolved.fillColors
        cachedStrokeColors = resolved.strokeColors

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, layer) in capsuleLayers.enumerated() where index < cachedColors.count {
            layer.backgroundColor = cachedColors[index]
        }
        for (index, layer) in strokeLayers.enumerated() where index < cachedStrokeColors.count {
            layer.strokeColor = cachedStrokeColors[index]
        }
        CATransaction.commit()
    }

    private func setupCapsuleLayers() {
        capsuleLayers = (0..<9).map { _ in
            let layer = CALayer()
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.actions = [
                "bounds": NSNull(),
                "position": NSNull(),
                "frame": NSNull(),
                "backgroundColor": NSNull(),
                "cornerRadius": NSNull(),
            ]
            rootLayer.addSublayer(layer)
            return layer
        }

        strokeLayers = (0..<9).map { _ in
            let layer = CAShapeLayer()
            layer.fillColor = nil
            layer.lineWidth = 0.5
            layer.actions = [
                "path": NSNull(),
                "strokeColor": NSNull(),
            ]
            rootLayer.addSublayer(layer)
            return layer
        }
    }

    private func applyWave(_ wave: [Float]) {
        guard isCurrentlyPlaying else { return }
        
        var normalized = Array(repeating: Float(0), count: 9)
        for index in 0..<9 {
            if index < wave.count {
                normalized[index] = min(1, max(0, wave[index]))
            }
        }

        let maxDelta = zip(currentWave, normalized).reduce(Float.zero) { partial, pair in
            max(partial, abs(pair.0 - pair.1))
        }
        guard maxDelta >= 0.002 else { return }

        currentWave = normalized
        layoutCapsules()
    }

    private func layoutCapsules() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        let width = bounds.width
        let height = bounds.height
        let capsuleCount = 9
        let maxBarHeightRatio: CGFloat = 0.95

        let barWidth = dotSize
        let minHeight = barWidth
        let maxBarHeight = height * maxBarHeightRatio
        let barSpacing = spacing
        let totalWidth = CGFloat(capsuleCount) * barWidth + CGFloat(capsuleCount - 1) * barSpacing

        let originX = (width - totalWidth) * 0.5
        let centerY = height * 0.5
        let cornerRadius = barWidth * 0.5

        rootLayer.frame = bounds

        let sourceWave = frozenWave ?? currentWave

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in 0..<capsuleCount {
            var value = CGFloat(sourceWave[index])
            
            if pausedBehavior == .minimalDots {
                value = value * (1.0 - pauseTransitionProgress)
            }
            
            let dynamicHeight = minHeight + (maxBarHeight - minHeight) * min(1, max(0, value))
            let x = originX + CGFloat(index) * (barWidth + barSpacing) + barWidth * 0.5
            let y = centerY

            let frame = CGRect(
                x: x - barWidth * 0.5,
                y: y - dynamicHeight * 0.5,
                width: barWidth,
                height: dynamicHeight
            )
            let layer = capsuleLayers[index]
            layer.frame = frame
            layer.cornerRadius = cornerRadius

            let strokeLayer = strokeLayers[index]
            let path = NSBezierPath(roundedRect: frame, xRadius: cornerRadius, yRadius: cornerRadius)
            strokeLayer.path = path.cgPath
        }
        CATransaction.commit()
    }

    private static func resolveStaticLightModeColors(from accentColor: NSColor) -> (fillColors: [CGColor], strokeColors: [CGColor]) {
        guard let staticRGB = accentColor.usingColorSpace(.deviceRGB) else {
            return (Array(repeating: CGColor(gray: 0.7, alpha: 0.85), count: 9),
                    Array(repeating: CGColor(gray: 0.6, alpha: 0.95), count: 9))
        }
        
        let leftBase = NSColor(red: staticRGB.redComponent,
                              green: staticRGB.greenComponent,
                              blue: staticRGB.blueComponent,
                              alpha: 1.0)
        let rightBase = makeSecondaryColor(leftBase)
        
        let total = max(1, 9 - 1)
        var fillColors: [CGColor] = []
        var strokeColors: [CGColor] = []
        
        for index in 0..<9 {
            let t = CGFloat(index) / CGFloat(total)
            let r = leftBase.redComponent + (rightBase.redComponent - leftBase.redComponent) * t
            let g = leftBase.greenComponent + (rightBase.greenComponent - leftBase.greenComponent) * t
            let b = leftBase.blueComponent + (rightBase.blueComponent - leftBase.blueComponent) * t
            let interpolated = NSColor(red: r, green: g, blue: b, alpha: 1.0)
            
            let finalFill = normalizeForMiniPlayer(interpolated)
            
            var hue: CGFloat = 0
            var sat: CGFloat = 0
            var bri: CGFloat = 0
            var alp: CGFloat = 0
            finalFill.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alp)
            
            let strokeBri = max(0.0, bri - 0.06)
            let strokeSat = min(1.0, sat + 0.15)
            let strokeColor = NSColor(hue: hue, saturation: strokeSat, brightness: strokeBri, alpha: 0.95)
            
            fillColors.append(finalFill.cgColor)
            strokeColors.append(strokeColor.cgColor)
        }
        
        return (fillColors, strokeColors)
    }

    private static func hslLightness(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return 0.5 }
        let maxC = max(rgb.redComponent, max(rgb.greenComponent, rgb.blueComponent))
        let minC = min(rgb.redComponent, min(rgb.greenComponent, rgb.blueComponent))
        return (maxC + minC) / 2.0
    }

    private static func normalizeForMiniPlayer(_ color: NSColor, minLightness: CGFloat = 0.50) -> NSColor {
        let L = hslLightness(color)
        guard L < minLightness else { return color }
        
        var hue: CGFloat = 0
        var sat: CGFloat = 0
        var bri: CGFloat = 0
        var alp: CGFloat = 0
        color.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alp)
        
        let liftAmount = minLightness - L
        let saturationCap = max(0.45, 0.80 - liftAmount * 1.5)
        let safeSat = min(sat, saturationCap)
        let safeBri = max(bri, minLightness + 0.08)
        
        return NSColor(hue: hue, saturation: safeSat, brightness: safeBri, alpha: 0.85)
    }

    private static func makeSecondaryColor(_ color: NSColor) -> NSColor {
        var hue: CGFloat = 0
        var sat: CGFloat = 0
        var bri: CGFloat = 0
        var alp: CGFloat = 0
        color.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alp)
        let shiftedHue = fmod(hue + 0.08, 1.0)
        return NSColor(hue: shiftedHue, saturation: sat * 0.85, brightness: bri * 1.08, alpha: alp * 0.9)
    }

    private static func clampToLightnessFloor(_ color: NSColor, minLightness: CGFloat = 0.50) -> NSColor {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return color }
        let r = rgb.redComponent
        let g = rgb.greenComponent
        let b = rgb.blueComponent
        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let lightness = (maxC + minC) / 2.0
        guard lightness < minLightness else { return color }
        var hue: CGFloat = 0
        var sat: CGFloat = 0
        var bri: CGFloat = 0
        var alp: CGFloat = 0
        color.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alp)
        let safeSat = min(sat, 0.65)
        let newBri = max(bri, minLightness + 0.05)
        return NSColor(hue: hue, saturation: safeSat, brightness: newBri, alpha: alp)
    }

    private static func makeCapsuleColorsWithStroke(
        accentColor: NSColor,
        isDark: Bool
    ) -> (fill: [CGColor], stroke: [CGColor]) {
        let leftBase = clampToLightnessFloor(accentColor)
        let rightBase = clampToLightnessFloor(makeSecondaryColor(accentColor))
        let total = max(1, 9 - 1)

        var fillColors: [CGColor] = []
        var strokeColors: [CGColor] = []

        for index in 0..<9 {
            let t = CGFloat(index) / CGFloat(total)
            let fillColor = makeInterpolatedColor(
                leftBase: leftBase,
                rightBase: rightBase,
                t: t,
                isDark: isDark
            )
            fillColors.append(fillColor.cgColor)

            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var alpha: CGFloat = 0
            fillColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

            let strokeBrightness: CGFloat
            let strokeSaturation: CGFloat
            let strokeAlpha: CGFloat

            if isDark {
                strokeBrightness = min(1.0, brightness + 0.35)
                strokeSaturation = min(1.0, saturation + 0.25)
                strokeAlpha = min(1.0, alpha + 0.1)
            } else {
                strokeBrightness = max(0.0, brightness - 0.06)
                strokeSaturation = min(1.0, saturation + 0.15)
                strokeAlpha = min(1.0, alpha + 0.1)
            }

            let strokeColor = NSColor(
                hue: hue,
                saturation: strokeSaturation,
                brightness: strokeBrightness,
                alpha: strokeAlpha
            )
            strokeColors.append(strokeColor.cgColor)
        }

        return (fillColors, strokeColors)
    }

    private static func makeCapsuleColors(accentColor: NSColor, isDark: Bool) -> [CGColor] {
        let leftBase = clampToLightnessFloor(accentColor)
        let rightBase = clampToLightnessFloor(makeSecondaryColor(accentColor))
        let total = max(1, 9 - 1)

        return (0..<9).map { index in
            let t = CGFloat(index) / CGFloat(total)
            return makeInterpolatedColor(
                leftBase: leftBase,
                rightBase: rightBase,
                t: t,
                isDark: isDark
            ).cgColor
        }
    }

    private static func makeInterpolatedColor(
        leftBase: NSColor,
        rightBase: NSColor,
        t: CGFloat,
        isDark: Bool
    ) -> NSColor {
        guard
            let c1 = leftBase.usingColorSpace(.deviceRGB),
            let c2 = rightBase.usingColorSpace(.deviceRGB)
        else {
            return leftBase
        }

        let red = c1.redComponent + (c2.redComponent - c1.redComponent) * t
        let green = c1.greenComponent + (c2.greenComponent - c1.greenComponent) * t
        let blue = c1.blueComponent + (c2.blueComponent - c1.blueComponent) * t
        let interpolated = NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        interpolated.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let targetBrightness: CGFloat
        let targetAlpha: CGFloat

        if isDark {
            targetBrightness = max(0.10, min(0.14, brightness * 0.4))
            targetAlpha = 0.8
            saturation *= 0.9
        } else {
            targetBrightness = min(max(0.1, brightness * 0.7), 0.55)
            targetAlpha = 0.85
        }

        return NSColor(
            hue: hue,
            saturation: saturation,
            brightness: targetBrightness,
            alpha: targetAlpha
        )
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

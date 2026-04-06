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
        // Use artwork-faithful colors for fullscreen mini player spectrum
        // This preserves the artwork's hue/chroma more truthfully without oversaturation
        let resolved = Self.resolveArtworkFaithfulColors(from: accentColor)
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

    /// Fullscreen mini player spectrum colors that faithfully represent artwork palette.
    /// Preserves artwork hue/chroma with minimal adjustment for visibility against glass background.
    private static func resolveArtworkFaithfulColors(from accentColor: NSColor) -> (fillColors: [CGColor], strokeColors: [CGColor]) {
        guard let inputRGB = accentColor.usingColorSpace(.deviceRGB) else {
            return (Array(repeating: CGColor(gray: 0.6, alpha: 0.85), count: 9),
                    Array(repeating: CGColor(gray: 0.5, alpha: 0.7), count: 9))
        }
        
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        inputRGB.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        
        let faithfulSat: CGFloat
        if s > 0.72 {
            faithfulSat = s * 0.88
        } else if s > 0.55 {
            faithfulSat = s * 0.94
        } else {
            faithfulSat = s
        }
        
        let faithfulBri: CGFloat
        if b < 0.28 {
            faithfulBri = b + 0.22
        } else if b > 0.85 {
            faithfulBri = b - 0.12
        } else {
            faithfulBri = b
        }
        
        let leftBase = NSColor(hue: h, saturation: faithfulSat, brightness: faithfulBri, alpha: 0.85)
        
        let shiftedHue = fmod(h + 0.06, 1.0)
        let secondarySat = faithfulSat * 0.92
        let secondaryBri = min(1.0, faithfulBri + 0.06)
        let rightBase = NSColor(hue: shiftedHue, saturation: secondarySat, brightness: secondaryBri, alpha: 0.80)
        
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
            var sh: CGFloat = 0, ss: CGFloat = 0, sb: CGFloat = 0, sa: CGFloat = 0
            strokeHSB.getHue(&sh, saturation: &ss, brightness: &sb, alpha: &sa)
            
            let strokeBri = max(0.12, sb - 0.04)
            let strokeAlpha = 0.92
            let strokeColor = NSColor(hue: sh, saturation: ss, brightness: strokeBri, alpha: strokeAlpha)
            
            fillColors.append(fillColor.cgColor)
            strokeColors.append(strokeColor.cgColor)
        }
        
        return (fillColors, strokeColors)
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

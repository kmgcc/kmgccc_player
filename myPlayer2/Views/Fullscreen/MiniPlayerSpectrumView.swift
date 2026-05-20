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
    let artworkColors: [NSColor]
    let usesDarkForeground: Bool
    let scale: CGFloat
    let isHovered: Bool
    let pausedBehavior: MiniPlayerSpectrumPausedBehavior

    init(
        isPlaying: Bool,
        accentColor: Color?,
        artworkColors: [NSColor] = [],
        usesDarkForeground: Bool = false,
        scale: CGFloat,
        isHovered: Bool,
        pausedBehavior: MiniPlayerSpectrumPausedBehavior
    ) {
        self.isPlaying = isPlaying
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
    let accentColor: NSColor
    let artworkColors: [NSColor]
    let usesDarkForeground: Bool
    let dotSize: CGFloat
    let spacing: CGFloat
    let pausedBehavior: MiniPlayerSpectrumPausedBehavior

    func makeNSView(context: Context) -> MiniPlayerSpectrumHostView {
        let view = MiniPlayerSpectrumHostView()
        view.dotSize = dotSize
        view.spacing = spacing
        view.pausedBehavior = pausedBehavior
        view.updateColors(
            accentColor: accentColor,
            artworkColors: artworkColors,
            usesDarkForeground: usesDarkForeground
        )
        view.start()
        view.setPlayback(isPlaying: isPlaying)
        return view
    }

    func updateNSView(_ nsView: MiniPlayerSpectrumHostView, context: Context) {
        nsView.dotSize = dotSize
        nsView.spacing = spacing
        nsView.pausedBehavior = pausedBehavior
        nsView.updateColors(
            accentColor: accentColor,
            artworkColors: artworkColors,
            usesDarkForeground: usesDarkForeground
        )
        nsView.setPlayback(isPlaying: isPlaying)
    }

    static func dismantleNSView(_ nsView: MiniPlayerSpectrumHostView, coordinator: ()) {
        nsView.stop()
    }
}

extension MiniPlayerSpectrumContainer: Equatable {
    static func == (lhs: MiniPlayerSpectrumContainer, rhs: MiniPlayerSpectrumContainer) -> Bool {
        lhs.isPlaying == rhs.isPlaying
            && lhs.dotSize == rhs.dotSize
            && lhs.spacing == rhs.spacing
            && lhs.pausedBehavior == rhs.pausedBehavior
            && lhs.accentColor.isVisuallyEqual(to: rhs.accentColor)
            && lhs.usesDarkForeground == rhs.usesDarkForeground
            && lhs.artworkColors.isVisuallyEqual(to: rhs.artworkColors)
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

    func updateColors(
        accentColor: NSColor,
        artworkColors: [NSColor],
        usesDarkForeground: Bool
    ) {
        // Use the artwork's two strongest colours for fullscreen mini player spectrum.
        // The same foreground-mode decision as the rest of the Clear mini player
        // decides whether the bars are darkened or lifted for readability.
        let resolved = Self.resolveArtworkFaithfulColors(
            from: artworkColors,
            fallback: accentColor,
            usesDarkForeground: usesDarkForeground
        )
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
    ///
    /// Phase 3: callers now pass `analysis.displayPalette.prefix(2)`. When the
    /// artwork is colour-thin (displayPalette has only 1 entry), avoid the
    /// hue-rotate fabricate path that older builds used; instead derive the
    /// right endpoint as a same-hue OKLCH tonal variant of the single real
    /// colour. This keeps the L→R gradient quietly informative rather than
    /// a flat strip while still being honest about what the artwork
    /// actually contains.
    private static func resolveArtworkFaithfulColors(
        from artworkColors: [NSColor],
        fallback accentColor: NSColor,
        usesDarkForeground: Bool
    ) -> (fillColors: [CGColor], strokeColors: [CGColor]) {
        let sources = Array(artworkColors.prefix(2))
        let leftSource = sources.first ?? accentColor
        let rightSource: NSColor = {
            if let explicit = sources.dropFirst().first {
                return explicit
            }
            // Single-colour path: build a same-hue L variant of the lone real
            // colour. No hue rotation. Falls back to accent only when even
            // OKLCH conversion fails.
            return makeTonalRightEndpoint(of: leftSource, usesDarkForeground: usesDarkForeground)
                ?? accentColor
        }()

        guard
            let leftBase = adjustedSpectrumBase(
                from: leftSource,
                usesDarkForeground: usesDarkForeground,
                alpha: 0.86
            ),
            let rightBase = adjustedSpectrumBase(
                from: rightSource,
                usesDarkForeground: usesDarkForeground,
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
            var sh: CGFloat = 0, ss: CGFloat = 0, sb: CGFloat = 0, sa: CGFloat = 0
            strokeHSB.getHue(&sh, saturation: &ss, brightness: &sb, alpha: &sa)
            
            let strokeBri = usesDarkForeground
                ? min(0.36, max(0.12, sb - 0.05))
                : min(1.0, max(0.58, sb + 0.08))
            let strokeAlpha = usesDarkForeground ? 0.78 : 0.92
            let strokeColor = NSColor(hue: sh, saturation: ss, brightness: strokeBri, alpha: strokeAlpha)
            
            fillColors.append(fillColor.cgColor)
            strokeColors.append(strokeColor.cgColor)
        }
        
        return (fillColors, strokeColors)
    }

    /// Build a same-hue tonal right endpoint for the single-real-colour
    /// path. Used when only one displayPalette colour is available so the
    /// gradient still has some L→R differentiation without inventing hues.
    private static func makeTonalRightEndpoint(
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

    private static func clamp01(_ value: CGFloat) -> CGFloat {
        min(1, max(0, value))
    }

    private static func adjustedSpectrumBase(
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
            // Phase 3 hotfix: near-mono input must pass through. The legacy
            // `max(0.18, s * 1.08)` floor amplified residual hue from grey
            // artwork into visible pink/yellow tint. Caller has already
            // OKLCH-neutralised near-mono colours, but enforce the floor
            // removal here too as a defence-in-depth so any future spectrum
            // consumer keeps the contract.
            tunedSaturation = s
        } else if s < 0.22 {
            // Phase 3 hotfix: low-saturation but not near-mono. Preserve
            // the artwork's muted impression instead of lifting toward
            // 0.18+ (which read as "more colourful than the cover").
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

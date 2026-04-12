//
//  ClassicLEDSkin.swift
//  myPlayer2
//
//  kmgccc_player - Classic Cover Skin
//

import SwiftUI

struct ClassicLEDSkin: NowPlayingSkin {
    static let id: String = "coverLed"

    let id: String = ClassicLEDSkin.id
    let name: String = NSLocalizedString("skin.classic_led.name", comment: "")
    let detail: String = NSLocalizedString("skin.classic_led.detail", comment: "")
    let systemImage: String = "dot.radiowaves.left.and.right"
    var isFullscreenCompatible: Bool { true }
    var isNowPlayingCompatible: Bool { true }

    func makeBackground(context: SkinContext) -> AnyView {
        AnyView(UnifiedNowPlayingBackground(context: context))
    }

    func makeArtwork(context: SkinContext) -> AnyView {
        AnyView(ClassicLEDArtwork(context: context))
    }

    var settingsView: AnyView? {
        AnyView(ClassicLEDSkinNormalSettingsView())
    }

    var fullscreenSettingsView: AnyView? {
        AnyView(ClassicLEDSkinFullscreenSettingsView())
    }
}

private struct ClassicLEDArtwork: View {
    let context: SkinContext
    @StateObject private var fullscreenManager = FullscreenWindowManager.shared

    @AppStorage("skin.classicLED.visualizerMode") private var normalVisualizerMode: String = "off"
    @AppStorage("skin.classicLED.fullscreen.visualizerMode") private var fullscreenVisualizerMode: String = "led"

    // MARK: - Fullscreen Fine-tuning Constants
    /// Slight boost to artwork size in fullscreen (1.0 = no change)
    private let fullscreenArtworkBoost: CGFloat = 1.22
    /// Horizontal shift for artwork in fullscreen (negative = left)
    private let fullscreenLeftShift: CGFloat = -40
    /// Additional visual scale applied to the cover stack in fullscreen.
    /// Applied via scaleEffect inside the scaled canvas, so it is
    /// resolution-stable (proportional to the base canvas, not screen pixels).
    private let fullscreenCoverScaleEffect: CGFloat = 1.2

    var body: some View {
        let contentSize = context.contentSize
        let isFullscreen = fullscreenManager.isFullscreenActive

        // Apply fullscreen boost and left shift only in fullscreen mode
        // Only shift left when lyrics are visible; when no lyrics, artwork should center
        let artworkBoost = isFullscreen ? fullscreenArtworkBoost : 1.0
        let leftShift = (isFullscreen && context.lyricsVisible) ? fullscreenLeftShift : 0

        let scaleFactor: CGFloat = isFullscreen ? 0.6 : 0.5
        let maxSizeBase: CGFloat = isFullscreen ? 480 : 360
        // Calculate base canvas size with boost, parent container handles the fullscreenScale
        let maxSize = maxSizeBase * artworkBoost
        let maxArtwork = min(contentSize.width * scaleFactor, contentSize.height * scaleFactor, maxSize)
        let artworkSize = max(180 * artworkBoost, maxArtwork)
        let effectSpacing: CGFloat = isFullscreen ? 32 : 24
        // yOffset should be fixed in base canvas coordinates, not scaled
        let yOffset: CGFloat = isFullscreen ? 32 : 18

        let visualizerMode = isFullscreen ? fullscreenVisualizerMode : normalVisualizerMode
        let dotSize: CGFloat = isFullscreen ? 12 : 10
        let spacing: CGFloat = isFullscreen ? 8 : 6

        VStack(spacing: effectSpacing) {
            artworkView
                .frame(width: artworkSize, height: artworkSize)
                // Shadow in base canvas coordinates - parent scaleEffect handles scaling
                .shadow(color: .black.opacity(0.35), radius: 20, x: 0, y: 10)

            if visualizerMode == "led" {
                LedMeterView(
                    level: Double(context.audio.smoothedLevel),
                    ledValues: context.led.leds,
                    dotSize: dotSize,
                    spacing: spacing,
                    pillTint: context.theme.artworkAccentColor
                )
            } else if visualizerMode == "spectrum" {
                PillSpectrumView(
                    context: context,
                    dotSize: dotSize,
                    spacing: spacing,
                    pillTint: context.theme.artworkAccentColor,
                    isFullscreen: isFullscreen
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(isFullscreen ? fullscreenCoverScaleEffect : 1.0)
        .offset(x: leftShift, y: yOffset)
    }

    @ViewBuilder
    private var artworkView: some View {
        // Corner radius in base canvas coordinates
        let cornerRadius: CGFloat = 12
        if let image = context.track?.artworkImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            ArtworkPlaceholderView.nowPlaying(
                size: min(context.contentSize.width, context.contentSize.height) * 0.5,
                cornerRadius: cornerRadius
            )
        }
    }
}

private struct ClassicLEDSkinNormalSettingsView: View {
    @AppStorage("skin.classicLED.visualizerMode") private var visualizerMode: String = "off"
    @Environment(LEDMeterServiceProvider.self) private var ledMeterProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("LED 电平表", isOn: Binding(
                get: { visualizerMode == "led" },
                set: { isOn in
                    if isOn {
                        visualizerMode = "led"
                        ledMeterProvider.getOrCreate().start()
                    } else if visualizerMode == "led" {
                        visualizerMode = "off"
                        ledMeterProvider.releaseNowPlayingResources()
                    }
                }
            ))
            .toggleStyle(.switch)

            Toggle("频谱动画", isOn: Binding(
                get: { visualizerMode == "spectrum" },
                set: { isOn in
                    if isOn {
                        visualizerMode = "spectrum"
                        ledMeterProvider.releaseNowPlayingResources()
                    } else if visualizerMode == "spectrum" {
                        visualizerMode = "off"
                    }
                }
            ))
            .toggleStyle(.switch)
        }
    }
}

private struct ClassicLEDSkinFullscreenSettingsView: View {
    @Environment(LEDMeterServiceProvider.self) private var ledMeterProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("LED 电平表", isOn: Binding(
                get: {
                    FullscreenPresentationCoordinator.shared.isSkinVisualizerEnabled
                    && UserDefaults.standard.string(forKey: "skin.classicLED.fullscreen.visualizerMode") == "led"
                },
                set: { isOn in
                    if isOn {
                        UserDefaults.standard.set("led", forKey: "skin.classicLED.fullscreen.visualizerMode")
                        FullscreenPresentationCoordinator.shared.setVisualizerMode(.skinVisualizer)
                    } else {
                        FullscreenPresentationCoordinator.shared.setVisualizerMode(.off)
                    }
                }
            ))
            .toggleStyle(.switch)

            Toggle("频谱动画", isOn: Binding(
                get: {
                    FullscreenPresentationCoordinator.shared.isSkinVisualizerEnabled
                    && UserDefaults.standard.string(forKey: "skin.classicLED.fullscreen.visualizerMode") == "spectrum"
                },
                set: { isOn in
                    if isOn {
                        UserDefaults.standard.set("spectrum", forKey: "skin.classicLED.fullscreen.visualizerMode")
                        FullscreenPresentationCoordinator.shared.setVisualizerMode(.skinVisualizer)
                    } else {
                        FullscreenPresentationCoordinator.shared.setVisualizerMode(.off)
                    }
                }
            ))
            .toggleStyle(.switch)
        }
    }
}

private struct PillSpectrumView: View {
    let context: SkinContext
    let dotSize: CGFloat
    let spacing: CGFloat
    let pillTint: Color?
    let isFullscreen: Bool
    @Environment(\.colorScheme) private var colorScheme

    private let capsuleCount: CGFloat = 9
    private let capsuleWidth: CGFloat = 7
    private let capsuleSpacing: CGFloat = 10
    private let horizontalPadding: CGFloat = 28
    private let contentHeight: CGFloat = 52  // Spectrum bars height (increased from 48)
    private var verticalPadding: CGFloat {
        isFullscreen ? 5 : 8  // Slightly shorter background pill in fullscreen
    }

    private var contentWidth: CGFloat {
        capsuleCount * capsuleWidth + (capsuleCount - 1) * capsuleSpacing
    }

    private var backgroundWidth: CGFloat {
        contentWidth + horizontalPadding * 2
    }

    private var backgroundHeight: CGFloat {
        contentHeight + verticalPadding * 2
    }

    var body: some View {
        PillSpectrumContainer(
            isPlaying: context.playback.isPlaying,
            isDark: context.theme.colorScheme == .dark,
            artworkPalette: Array(context.theme.artworkPalette.prefix(2)),
            artworkAccentColor: NSColor(pillTint ?? .white),
            capsuleWidth: capsuleWidth,
            capsuleSpacing: capsuleSpacing
        )
        .frame(width: contentWidth, height: contentHeight)
        .background(
            Capsule()
                .fill(Color.clear)
                .frame(width: backgroundWidth, height: backgroundHeight)
                .liquidGlassPill(
                    colorScheme: colorScheme,
                    accentColor: pillTint,
                    prominence: pillTint != nil ? .prominent : .standard,
                    isFloating: false
                )
        )
    }
}

private struct PillSpectrumContainer: NSViewRepresentable {
    let isPlaying: Bool
    let isDark: Bool
    let artworkPalette: [NSColor]
    let artworkAccentColor: NSColor
    let capsuleWidth: CGFloat
    let capsuleSpacing: CGFloat

    func makeNSView(context: Context) -> PillSpectrumHostView {
        let view = PillSpectrumHostView()
        view.capsuleWidth = capsuleWidth
        view.capsuleSpacing = capsuleSpacing
        view.updatePalette(artworkPalette, accentColor: artworkAccentColor, isDark: isDark)
        view.start()
        view.setPlayback(isPlaying: isPlaying)
        return view
    }

    func updateNSView(_ nsView: PillSpectrumHostView, context: Context) {
        nsView.capsuleWidth = capsuleWidth
        nsView.capsuleSpacing = capsuleSpacing
        nsView.updatePalette(artworkPalette, accentColor: artworkAccentColor, isDark: isDark)
        nsView.setPlayback(isPlaying: isPlaying)
    }

    static func dismantleNSView(_ nsView: PillSpectrumHostView, coordinator: ()) {
        nsView.stop()
    }
}

@MainActor
private final class PillSpectrumHostView: NSView {
    private let service = AudioVisualizationService.shared
    private let rootLayer = CALayer()
    private var capsuleLayers: [CALayer] = []
    private var strokeLayers: [CAShapeLayer] = []
    private var consumerID: UUID?

    private var currentWave = Array(repeating: Float(0), count: 9)
    private var cachedColors: [CGColor] = []
    private var cachedStrokeColors: [CGColor] = []
    private var paletteSignature: Int = 0
    private var lastPlaybackState: Bool?
    private var lastLayoutSize: CGSize = .zero

    var capsuleWidth: CGFloat = 6
    var capsuleSpacing: CGFloat = 6

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
        service.stop()
        currentWave = Array(repeating: 0, count: 9)
        layoutCapsules()
    }

    func setPlayback(isPlaying: Bool) {
        guard lastPlaybackState != isPlaying else { return }
        lastPlaybackState = isPlaying
        service.updatePlaybackState(isPlaying: isPlaying)
    }

    func updatePalette(_ palette: [NSColor], accentColor: NSColor, isDark: Bool) {
        let signature = Self.paletteSignature(
            palette: palette,
            accentColor: accentColor,
            isDark: isDark
        )
        guard signature != paletteSignature else { return }

        paletteSignature = signature
        let (fillColors, strokeColors) = Self.makeCapsuleColorsWithStroke(
            palette: palette,
            accentColor: accentColor,
            isDark: isDark
        )
        cachedColors = fillColors
        cachedStrokeColors = strokeColors

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

        let barWidth = capsuleWidth
        let minHeight = barWidth
        let maxBarHeight = height * maxBarHeightRatio
        let spacing = capsuleSpacing
        let totalWidth = CGFloat(capsuleCount) * barWidth + CGFloat(capsuleCount - 1) * spacing
        let originX = (width - totalWidth) * 0.5
        let centerY = height * 0.5
        let cornerRadius = barWidth * 0.5

        rootLayer.frame = bounds

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in 0..<capsuleCount {
            let value = CGFloat(currentWave[index])
            let dynamicHeight = minHeight + (maxBarHeight - minHeight) * min(1, max(0, value))
            let x = originX + CGFloat(index) * (barWidth + spacing) + barWidth * 0.5
            let y = centerY

            let frame = CGRect(x: x - barWidth * 0.5, y: y - dynamicHeight * 0.5, width: barWidth, height: dynamicHeight)
            let layer = capsuleLayers[index]
            layer.frame = frame
            layer.cornerRadius = cornerRadius

            let strokeLayer = strokeLayers[index]
            let path = NSBezierPath(roundedRect: frame, xRadius: cornerRadius, yRadius: cornerRadius)
            strokeLayer.path = path.cgPath
        }
        CATransaction.commit()
    }

    private static func paletteSignature(palette: [NSColor], accentColor: NSColor, isDark: Bool) -> Int {
        var hasher = Hasher()
        hasher.combine(isDark)
        for color in palette.prefix(2) {
            append(color: color, to: &hasher)
        }
        append(color: accentColor, to: &hasher)
        return hasher.finalize()
    }

    private static func append(color: NSColor, to hasher: inout Hasher) {
        let resolved = color.usingColorSpace(.deviceRGB) ?? color
        hasher.combine(Int(resolved.redComponent * 1_000))
        hasher.combine(Int(resolved.greenComponent * 1_000))
        hasher.combine(Int(resolved.blueComponent * 1_000))
        hasher.combine(Int(resolved.alphaComponent * 1_000))
    }

    private static func makeCapsuleColors(
        palette: [NSColor],
        accentColor: NSColor,
        isDark: Bool
    ) -> [CGColor] {
        let colors: [NSColor]
        if palette.count >= 2 {
            colors = Array(palette.prefix(2))
        } else {
            colors = [accentColor, accentColor.withAlphaComponent(0.7)]
        }

        let leftBase = colors[0]
        let rightBase = colors[min(1, colors.count - 1)]
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

    private static func makeCapsuleColorsWithStroke(
        palette: [NSColor],
        accentColor: NSColor,
        isDark: Bool
    ) -> (fill: [CGColor], stroke: [CGColor]) {
        let colors: [NSColor]
        if palette.count >= 2 {
            colors = Array(palette.prefix(2))
        } else {
            colors = [accentColor, accentColor.withAlphaComponent(0.7)]
        }

        let leftBase = colors[0]
        let rightBase = colors[min(1, colors.count - 1)]
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

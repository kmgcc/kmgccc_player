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

    @AppStorage("skin.classicLED.visualizerMode") private var normalVisualizerMode: String = "off"
    @AppStorage("skin.classicLED.fullscreen.visualizerMode") private var fullscreenVisualizerMode: String = "led"

    var body: some View {
        let visualizerMode = context.usesFullscreenPlayerLayout
            ? fullscreenVisualizerMode
            : normalVisualizerMode
        ClassicCoverArtworkView(
            context: context,
            visualizerMode: visualizerMode,
            presentation: .classic
        )
    }
}

struct ClassicCoverArtworkView: View {
    enum Presentation {
        case classic
        case appleStyle
    }

    let context: SkinContext
    let visualizerMode: String
    var forceBrightLEDColors: Bool = false
    var presentation: Presentation = .classic
    @Environment(\.displayScale) private var displayScale
    @AppStorage("skin.classicLED.artworkFrameMaskEnabled") private var artworkFrameMaskEnabled: Bool = true

    private var localArtworkScale: CGFloat {
        presentation == .classic && artworkFrameMaskEnabled ? 1.08 : 1.0
    }

    // MARK: - Fullscreen Fine-tuning Constants
    /// Slight boost to artwork size in fullscreen (1.0 = no change)
    private let fullscreenArtworkBoost: CGFloat = 1.22
    /// Additional visual scale applied to the cover stack in fullscreen.
    /// Applied via scaleEffect inside the scaled canvas, so it is
    /// resolution-stable (proportional to the base canvas, not screen pixels).
    private let fullscreenCoverScaleEffect: CGFloat = 1.2

    var body: some View {
        let contentSize = context.contentSize
        let usesFullscreenLayout = context.usesFullscreenPlayerLayout

        let artworkBoost = usesFullscreenLayout ? fullscreenArtworkBoost : 1.0
        let leftShift = FullscreenCoverHorizontalOffset.artworkOffsetX(for: context)

        let scaleFactor: CGFloat = usesFullscreenLayout ? 0.6 : 0.5
        let maxSizeBase: CGFloat = usesFullscreenLayout ? 480 : 360
        // Calculate base canvas size with boost, parent container handles the fullscreenScale
        let maxSize = maxSizeBase * artworkBoost
        let maxArtwork = min(contentSize.width * scaleFactor, contentSize.height * scaleFactor, maxSize)
        let artworkSize = max(180 * artworkBoost, maxArtwork) * localArtworkScale
        let effectSpacing: CGFloat = usesFullscreenLayout ? 32 : 24
        // yOffset should be fixed in base canvas coordinates, not scaled
        // Embedded fullscreen sits slightly lower than the dedicated fullscreen space,
        // so trim the fullscreen cover stack offset only for that host.
        let yOffset: CGFloat = usesFullscreenLayout
            ? (context.fullscreenHostMode == .embeddedWindow ? 12 : 32)
            : 18

        let dotSize: CGFloat = usesFullscreenLayout ? 14 : 12
        let spacing: CGFloat = usesFullscreenLayout ? 9 : 7

        VStack(spacing: effectSpacing) {
            artworkContainer(size: artworkSize)

            if visualizerMode == "led" {
                LedMeterView(
                    level: Double(context.audio.smoothedLevel),
                    ledValues: context.led.leds,
                    dotSize: dotSize,
                    spacing: spacing,
                    pillTint: context.theme.artworkAccentColor,
                    isPlaying: context.playback.isPlaying,
                    forceBrightLEDColors: forceBrightLEDColors || context.theme.artBackgroundIsUltraDark
                )
            } else if visualizerMode == "spectrum" {
                PillSpectrumView(
                    context: context,
                    dotSize: dotSize,
                    spacing: spacing,
                    pillTint: context.theme.artworkAccentColor,
                    isFullscreen: usesFullscreenLayout
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(usesFullscreenLayout ? fullscreenCoverScaleEffect : 1.0)
        .offset(x: leftShift, y: yOffset)
    }

    @ViewBuilder
    private func artworkContainer(size: CGFloat) -> some View {
        switch presentation {
        case .classic:
            ClassicArtworkCoverContainer(
                context: context,
                size: size,
                displayScale: displayScale
            )
        case .appleStyle:
            AppleStyleArtworkCoverContainer(
                context: context,
                size: size
            )
        }
    }
}

private struct ClassicArtworkCoverContainer: View {
    let context: SkinContext
    let size: CGFloat
    let displayScale: CGFloat

    @AppStorage("skin.classicLED.artworkFrameMaskEnabled") private var artworkFrameMaskEnabled: Bool = true
    @State private var maskRefreshToken = 0

    private let cornerRadius: CGFloat = 12

    var body: some View {
        classicCoverContent
            .id(maskRefreshToken)
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .onTapGesture {
                advanceArtworkFrameMask()
            }
    }

    @ViewBuilder
    private var classicCoverContent: some View {
        if let image = context.track?.artworkImage {
            if let mask = artworkFrameMask {
                ArtworkFrameMaskedImageView(
                    image: image,
                    mask: mask,
                    size: size,
                    displayScale: displayScale
                )
            } else {
                RoundedCoverArtworkImage(image: image, size: size, cornerRadius: cornerRadius)
            }
        } else {
            ArtworkPlaceholderView.nowPlaying(
                size: min(context.contentSize.width, context.contentSize.height) * 0.5,
                cornerRadius: cornerRadius
            )
        }
    }

    private var artworkFrameMask: CGImage? {
        guard artworkFrameMaskEnabled else {
            return nil
        }

        let assets = BKThemeAssets.shared
        let frameCount = assets.artworkFrameCount
        let key = ClassicArtworkFrameMaskKey(track: context.track)
        guard let index = ClassicArtworkFrameMaskSelection.shared.maskIndex(
            for: key,
            frameCount: frameCount
        ) else {
            return nil
        }
        let targetPixel = max(1, Int(ceil(size * max(1, displayScale))))
        let maxPixel = ((targetPixel + 127) / 128) * 128
        return assets.artworkFrame(at: index, maxPixel: maxPixel)
    }

    private func advanceArtworkFrameMask() {
        guard artworkFrameMaskEnabled, context.track?.artworkImage != nil else {
            return
        }

        let assets = BKThemeAssets.shared
        let frameCount = assets.artworkFrameCount
        let key = ClassicArtworkFrameMaskKey(track: context.track)
        guard ClassicArtworkFrameMaskSelection.shared.advanceMask(
            for: key,
            frameCount: frameCount
        ) != nil else {
            return
        }

        maskRefreshToken &+= 1
    }
}

private struct AppleStyleArtworkCoverContainer: View {
    let context: SkinContext
    let size: CGFloat

    private let cornerRadius: CGFloat = 12

    var body: some View {
        ZStack {
            if let image = context.track?.artworkImage {
                RoundedCoverArtworkImage(image: image, size: size, cornerRadius: cornerRadius)
                    .blur(radius: 26)
                    .opacity(context.theme.colorScheme == .dark ? 0.34 : 0.26)
                    .allowsHitTesting(false)

                RoundedCoverArtworkImage(image: image, size: size, cornerRadius: cornerRadius)
            } else {
                ArtworkPlaceholderView.nowPlaying(
                    size: min(context.contentSize.width, context.contentSize.height) * 0.5,
                    cornerRadius: cornerRadius
                )
            }
        }
        .frame(width: size, height: size)
    }
}

private struct RoundedCoverArtworkImage: View {
    let image: NSImage
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct ArtworkFrameMaskedImageView: View {
    let image: NSImage
    let mask: CGImage
    let size: CGFloat
    let displayScale: CGFloat

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipped()
            .mask {
                Image(decorative: mask, scale: max(1, displayScale), orientation: .up)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
            }
    }
}

private struct ClassicLEDSkinNormalSettingsView: View {
    @AppStorage("skin.classicLED.visualizerMode") private var visualizerMode: String = "off"
    @AppStorage("skin.classicLED.artworkFrameMaskEnabled") private var artworkFrameMaskEnabled: Bool = true
    @Environment(LEDMeterServiceProvider.self) private var ledMeterProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSwitchRow(title: "艺术化封面边缘", isOn: $artworkFrameMaskEnabled)

            SettingsSwitchRow(title: "LED 电平表", isOn: Binding(
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

            SettingsSwitchRow(title: "频谱动画", isOn: Binding(
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
        }
    }
}

private struct ClassicLEDSkinFullscreenSettingsView: View {
    @Environment(LEDMeterServiceProvider.self) private var ledMeterProvider
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle
    @AppStorage("skin.classicLED.artworkFrameMaskEnabled") private var artworkFrameMaskEnabled: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
            SettingsSwitchRow(
                title: "艺术化封面边缘",
                isOn: $artworkFrameMaskEnabled,
                titleFont: presentationStyle.rowLabelFont,
                titleColor: presentationStyle.primaryTextColor
            )

            SettingsSwitchRow(title: "LED 电平表", isOn: Binding(
                get: {
                    FullscreenPresentationCoordinator.shared.isSkinVisualizerEnabled
                    && UserDefaults.standard.string(forKey: "skin.classicLED.fullscreen.visualizerMode") == "led"
                },
                set: { isOn in
                    if isOn {
                        UserDefaults.standard.set("led", forKey: "skin.classicLED.fullscreen.visualizerMode")
                        FullscreenPresentationCoordinator.shared.setVisualizerMode(.skinVisualizer)
                    } else {
                        UserDefaults.standard.set("off", forKey: "skin.classicLED.fullscreen.visualizerMode")
                        FullscreenPresentationCoordinator.shared.setVisualizerMode(.off)
                    }
                }
            ), titleFont: presentationStyle.rowLabelFont, titleColor: presentationStyle.primaryTextColor)

            SettingsSwitchRow(title: "频谱动画", isOn: Binding(
                get: {
                    FullscreenPresentationCoordinator.shared.isSkinVisualizerEnabled
                    && UserDefaults.standard.string(forKey: "skin.classicLED.fullscreen.visualizerMode") == "spectrum"
                },
                set: { isOn in
                    if isOn {
                        UserDefaults.standard.set("spectrum", forKey: "skin.classicLED.fullscreen.visualizerMode")
                        FullscreenPresentationCoordinator.shared.setVisualizerMode(.skinVisualizer)
                    } else {
                        UserDefaults.standard.set("off", forKey: "skin.classicLED.fullscreen.visualizerMode")
                        FullscreenPresentationCoordinator.shared.setVisualizerMode(.off)
                    }
                }
            ), titleFont: presentationStyle.rowLabelFont, titleColor: presentationStyle.primaryTextColor)
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
            usesDarkForeground: context.theme.spectrumUsesDarkForeground,
            artworkColors: context.theme.spectrumArtworkColors,
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
    let usesDarkForeground: Bool
    let artworkColors: [NSColor]
    let artworkAccentColor: NSColor
    let capsuleWidth: CGFloat
    let capsuleSpacing: CGFloat

    func makeNSView(context: Context) -> PillSpectrumHostView {
        let view = PillSpectrumHostView()
        view.capsuleWidth = capsuleWidth
        view.capsuleSpacing = capsuleSpacing
        view.updatePalette(artworkColors, accentColor: artworkAccentColor, usesDarkForeground: usesDarkForeground)
        view.start()
        view.setPlayback(isPlaying: isPlaying)
        return view
    }

    func updateNSView(_ nsView: PillSpectrumHostView, context: Context) {
        nsView.capsuleWidth = capsuleWidth
        nsView.capsuleSpacing = capsuleSpacing
        nsView.updatePalette(artworkColors, accentColor: artworkAccentColor, usesDarkForeground: usesDarkForeground)
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

    func updatePalette(_ artworkColors: [NSColor], accentColor: NSColor, usesDarkForeground: Bool) {
        let signature = Self.paletteSignature(
            artworkColors: artworkColors,
            accentColor: accentColor,
            usesDarkForeground: usesDarkForeground
        )
        guard signature != paletteSignature else { return }

        paletteSignature = signature
        let (fillColors, strokeColors) = SpectrumColorResolver.resolveArtworkFaithfulColors(
            from: artworkColors,
            fallback: accentColor,
            usesDarkForeground: usesDarkForeground
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

    private static func paletteSignature(artworkColors: [NSColor], accentColor: NSColor, usesDarkForeground: Bool) -> Int {
        var hasher = Hasher()
        hasher.combine(usesDarkForeground)
        for color in artworkColors.prefix(2) {
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

}

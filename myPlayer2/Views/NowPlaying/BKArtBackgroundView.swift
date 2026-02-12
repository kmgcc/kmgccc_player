//
//  BKArtBackgroundView.swift
//  myPlayer2
//
//  Now Playing artistic background:
//  - bk1/bk2 cycling at 1fps
//  - 10~16 opaque random tinted shapes
//  - transition via 6fps luma mask
//

import AppKit
import Combine
import CoreImage
import QuartzCore
import SwiftUI

@MainActor
final class BKArtBackgroundController: ObservableObject {
    @Published private(set) var transitionID: Int = 0

    func triggerTransition() {
        transitionID &+= 1
    }
}

struct BKArtBackgroundView: View {
    @ObservedObject var controller: BKArtBackgroundController
    let trackID: UUID?
    let artworkData: Data?

    @State private var palette: [NSColor] = Self.fallbackPalette

    var body: some View {
        BKArtBackgroundRepresentable(
            transitionID: controller.transitionID,
            seed: seedValue,
            palette: palette
        )
        .allowsHitTesting(false)
        .onAppear {
            refreshPalette()
        }
        .onChange(of: trackID) { _, _ in
            refreshPalette()
        }
        .onChange(of: artworkSignature) { _, _ in
            refreshPalette()
        }
    }

    private var seedValue: UInt64 {
        guard let id = trackID else { return 0xA17D_4C59_10F3_778D }
        return UInt64(bitPattern: Int64(id.uuidString.hashValue))
    }

    private var artworkSignature: Int {
        artworkData?.hashValue ?? 0
    }

    private func refreshPalette() {
        guard let data = artworkData else {
            palette = Self.fallbackPalette
            return
        }
        let extracted = ArtworkColorExtractor.uiThemePalette(from: data, maxColors: 4)
        palette = extracted.isEmpty ? Self.fallbackPalette : extracted
    }

    fileprivate static let fallbackPalette: [NSColor] = [
        NSColor(calibratedRed: 0.50, green: 0.62, blue: 0.76, alpha: 1.0),
        NSColor(calibratedRed: 0.76, green: 0.54, blue: 0.52, alpha: 1.0),
        NSColor(calibratedRed: 0.56, green: 0.72, blue: 0.46, alpha: 1.0),
    ]
}

private struct BKArtBackgroundRepresentable: NSViewRepresentable {
    let transitionID: Int
    let seed: UInt64
    let palette: [NSColor]

    final class Coordinator {
        weak var contentView: BKArtBackgroundLayerView?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSBackgroundExtensionView {
        let extensionView = NSBackgroundExtensionView()

        let contentView = BKArtBackgroundLayerView()
        contentView.translatesAutoresizingMaskIntoConstraints = false

        extensionView.contentView = contentView
        context.coordinator.contentView = contentView

        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(
                equalTo: extensionView.safeAreaLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(
                equalTo: extensionView.safeAreaLayoutGuide.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: extensionView.safeAreaLayoutGuide.topAnchor),
            contentView.bottomAnchor.constraint(
                equalTo: extensionView.safeAreaLayoutGuide.bottomAnchor),
        ])

        contentView.updatePalette(palette)
        contentView.ensureBaseContainer(seed: seed)
        contentView.currentTransitionID = transitionID
        return extensionView
    }

    func updateNSView(_ nsView: NSBackgroundExtensionView, context: Context) {
        guard
            let contentView = context.coordinator.contentView
                ?? (nsView.contentView as? BKArtBackgroundLayerView)
        else { return }

        contentView.updatePalette(palette)
        contentView.ensureBaseContainer(seed: seed)

        if contentView.currentTransitionID != transitionID {
            contentView.currentTransitionID = transitionID
            contentView.triggerTransition(seed: seed &+ UInt64(truncatingIfNeeded: transitionID))
        }
    }
}

@MainActor
private final class BKArtBackgroundLayerView: NSView {
    private struct ShapeState {
        var basePosition: CGPoint
        var driftX: CGFloat
        var driftY: CGFloat
        var phase: CGFloat
        var phaseSpeed: CGFloat
        var angle: CGFloat
        var angularSpeed: CGFloat
    }

    private enum BackgroundStyle: Int {
        case image = 0
        case dot = 1
    }

    private enum DotMotionState {
        case idle(TimeInterval)
        case moving(Double)
    }

    private struct DotAnimState {
        var motion: DotMotionState
        var start: CGPoint
        var cp1: CGPoint
        var cp2: CGPoint
        var end: CGPoint
        var duration: TimeInterval
    }

    private final class Container {
        let layer = CALayer()
        let backgroundLayer = CALayer()

        var style: BackgroundStyle = .image
        var dotRoot: CALayer?
        var dotMasks: [CAShapeLayer] = []
        var dotAnim: DotAnimState?
        var dotGradient: CAGradientLayer?
        var dotCells: [CAShapeLayer] = []  // Keep references to actual dot shapes
        var dotColor: CGColor?  // Current round color
        var backgroundTintLayer: CALayer?  // Tint layer for image backgrounds

        // Randomize sizes per run
        var dotBaseRadius: CGFloat = 0
        var dotRadiusLarge: CGFloat = 4.2
        var dotRadiusSmall: CGFloat = 2.5

        var shapeLayers: [CALayer] = []
        var shapeStates: [ShapeState] = []

        init(frame: CGRect) {
            layer.frame = frame
            layer.masksToBounds = true
            layer.backgroundColor = NSColor.black.cgColor
            backgroundLayer.frame = frame
            backgroundLayer.backgroundColor = NSColor.black.cgColor
            backgroundLayer.contentsGravity = .resizeAspectFill
            layer.addSublayer(backgroundLayer)
        }
    }

    var currentTransitionID: Int = 0

    private let assets = BKThemeAssets.shared
    private var palette: [CGColor] = BKArtBackgroundView.fallbackPalette.map(\.cgColor)
    private let ciContext = CIContext(options: [.cacheIntermediates: true])
    private var tintedBackgrounds: [CGImage] = []
    private var paletteSignature: String = ""
    private var processedMaskFrames: [CGImage] = []

    private var fromContainer: Container?
    private var toContainer: Container?
    private var transitionMaskLayer: CALayer?

    private var backgroundPhase: Int = 0
    private var maskFrameIndex: Int = 0
    private var lastLayoutSize: CGSize = .zero
    private var rebuildSeed: UInt64 = 0

    private var backgroundTimer: DispatchSourceTimer?
    private var shapeTimer: DispatchSourceTimer?
    private var dotTimer: DispatchSourceTimer?
    private var transitionTimer: DispatchSourceTimer?
    private var autoTransitionTimer: DispatchSourceTimer?
    private var transitionSeedCounter: UInt64 = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        backgroundTimer?.cancel()
        shapeTimer?.cancel()
        dotTimer?.cancel()
        transitionTimer?.cancel()
        autoTransitionTimer?.cancel()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopTimers()
        } else {
            startTimersIfNeeded()
        }
    }

    override func layout() {
        super.layout()
        guard !bounds.isEmpty else { return }
        layer?.frame = bounds

        if fromContainer == nil {
            ensureBaseContainer(seed: rebuildSeed)
        }

        if lastLayoutSize == .zero {
            lastLayoutSize = bounds.size
        } else if abs(lastLayoutSize.width - bounds.width) > 4
            || abs(lastLayoutSize.height - bounds.height) > 4
        {
            lastLayoutSize = bounds.size
            rebuildForCurrentBounds()
            return
        }

        layoutContainer(fromContainer)
        layoutContainer(toContainer)
        transitionMaskLayer?.frame = expandedBounds
    }

    func updatePalette(_ colors: [NSColor]) {
        guard !colors.isEmpty else { return }
        let converted = colors.map { ($0.usingColorSpace(.deviceRGB) ?? $0).cgColor }
        let signature = Self.paletteSignature(for: converted)
        guard signature != paletteSignature else { return }

        palette = converted
        paletteSignature = signature
        tintedBackgrounds = makeTintedBackgrounds(from: assets.backgrounds, palette: converted)
        applyCurrentBackgroundPhase()
    }

    func ensureBaseContainer(seed: UInt64) {
        rebuildSeed = seed
        guard fromContainer == nil, !bounds.isEmpty else { return }
        if tintedBackgrounds.isEmpty {
            tintedBackgrounds = makeTintedBackgrounds(from: assets.backgrounds, palette: palette)
        }
        let container = buildContainer(seed: seed)
        // Ensure initial container respects style choice
        if container.style == .image && tintedBackgrounds.isEmpty {
            // Fallback or retry? Should be fine as applyBackgroundPhase handles empty.
        }
        fromContainer = container
        layer?.addSublayer(container.layer)
        applyCurrentBackgroundPhase()
        startTimersIfNeeded()
    }

    func triggerTransition(seed: UInt64) {
        guard !bounds.isEmpty else { return }
        rebuildSeed = seed
        ensureBaseContainer(seed: seed)
        guard let current = fromContainer else { return }
        guard toContainer == nil else { return }

        stopTransitionTimer()
        let next = buildContainer(seed: seed ^ 0x9E37_79B9_7F4A_7C15)
        toContainer = next
        layer?.insertSublayer(next.layer, above: current.layer)
        applyBackgroundPhase(to: next)

        let maskFrames = resolvedMaskFrames()
        guard !maskFrames.isEmpty else {
            finalizeTransition()
            return
        }

        let mask = CALayer()
        mask.frame = expandedBounds
        mask.contentsGravity = .resize
        mask.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        mask.contents = maskFrames[0]
        next.layer.mask = mask
        transitionMaskLayer = mask
        maskFrameIndex = 0
        startTransitionTimer()
    }

    private func rebuildForCurrentBounds() {
        guard !bounds.isEmpty else { return }
        stopTransitionTimer()

        let replacement = buildContainer(seed: rebuildSeed)
        fromContainer?.layer.removeFromSuperlayer()
        toContainer?.layer.removeFromSuperlayer()
        transitionMaskLayer = nil
        fromContainer = replacement
        toContainer = nil

        layer?.addSublayer(replacement.layer)
        applyCurrentBackgroundPhase()
        startTimersIfNeeded()
    }

    private func layoutContainer(_ container: Container?) {
        guard let container else { return }
        container.layer.frame = expandedBounds
        container.backgroundLayer.frame = expandedBounds
        container.backgroundLayer.contentsScale =
            window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    }

    private func buildContainer(seed: UInt64) -> Container {
        let container = Container(frame: bounds)
        var rng = BKSeededRandom(seed: seed == 0 ? 0xA17D_4C59_10F3_778D : seed)

        // Decide style randomly (approx 50/50)
        container.style = rng.nextBool() ? .dot : .image

        if container.style == .dot {
            setupDotBackground(in: container, rng: &rng)
            // Dot mode hides the tint layer effectively by covering it, or we can explicit hide it later
        }

        // Tint Layer for Image Backgrounds (Add to every container, hide if dot)
        let tintLayer = CALayer()
        tintLayer.frame = expandedBounds  // Tint covers full bound
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        if isDark {
            tintLayer.backgroundColor = NSColor.black.cgColor
            tintLayer.opacity = 0.22  // Darken background 22%
        } else {
            tintLayer.backgroundColor = NSColor.white.cgColor
            tintLayer.opacity = 0.12  // Lighten background 12%
        }
        container.backgroundTintLayer = tintLayer
        container.layer.insertSublayer(tintLayer, above: container.backgroundLayer)

        if container.style == .image {
            // Shapes
            let count = rng.nextInt(in: 10...16)
            let chosenShapes = chooseShapeImages(count: count, rng: &rng)
            let rawTint = palette.randomElement() ?? palette[0]
            let nsTint = NSColor(cgColor: rawTint) ?? .white
            // Apply FG Tone to shapes
            let finalTint = applyForegroundTone(nsTint, mode: isDark ? .dark : .light).cgColor

            let forbiddenRect = CGRect(
                x: bounds.width * 0.28,
                y: bounds.height * 0.22,
                width: bounds.width * 0.44,
                height: bounds.height * 0.50
            )

            for image in chosenShapes {
                let base = min(bounds.width, bounds.height)
                let side = base * CGFloat(rng.next(in: 0.50...1.80)) * 0.22
                let point = randomEdgePoint(side: side, forbiddenRect: forbiddenRect, rng: &rng)

                let frame = CGRect(
                    x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
                // Use unified finalTint
                let shape = makeTintedShapeLayer(image: image, frame: frame, tint: finalTint)

                container.layer.insertSublayer(shape, above: tintLayer)
                container.shapeLayers.append(shape)

                let state = ShapeState(
                    basePosition: point,
                    driftX: CGFloat(rng.next(in: -12...12)),
                    driftY: CGFloat(rng.next(in: -16...16)),
                    phase: CGFloat(rng.next(in: 0...(Double.pi * 2))),
                    phaseSpeed: CGFloat(rng.next(in: 0.35...0.95)),
                    angle: CGFloat(rng.next(in: 0...(Double.pi * 2))),
                    angularSpeed: CGFloat(rng.next(in: -0.22...0.22))
                )
                container.shapeStates.append(state)
            }
        }

        return container
    }

    private func chooseShapeImages(count: Int, rng: inout BKSeededRandom) -> [CGImage] {
        guard !assets.shapes.isEmpty else { return [] }
        var indexed = Array(assets.shapes.enumerated())
        indexed.shuffle(using: &rng)
        if indexed.count >= count {
            return Array(indexed.prefix(count).map(\.element))
        }
        var output = indexed.map(\.element)
        while output.count < count {
            output.append(assets.shapes[Int(rng.next(in: 0..<Double(assets.shapes.count)))])
        }
        return output
    }

    private func randomEdgePoint(
        side: CGFloat,
        forbiddenRect: CGRect,
        rng: inout BKSeededRandom
    ) -> CGPoint {
        let edgeBandX = max(24, bounds.width * 0.18)
        let edgeBandY = max(24, bounds.height * 0.18)
        let half = side * 0.5
        let xRange = half...(bounds.width - half)
        let yRange = half...(bounds.height - half)

        for _ in 0..<28 {
            let sidePick = rng.next(in: 0.0..<1.0)
            let point: CGPoint
            if sidePick < 0.30 {
                point = CGPoint(
                    x: CGFloat(rng.next(in: Double(xRange.lowerBound)...Double(xRange.upperBound))),
                    y: CGFloat(
                        rng.next(
                            in: Double(yRange.upperBound - edgeBandY)...Double(yRange.upperBound)))
                )
            } else if sidePick < 0.60 {
                point = CGPoint(
                    x: CGFloat(rng.next(in: Double(xRange.lowerBound)...Double(xRange.upperBound))),
                    y: CGFloat(
                        rng.next(
                            in: Double(yRange.lowerBound)...Double(yRange.lowerBound + edgeBandY)))
                )
            } else if sidePick < 0.80 {
                point = CGPoint(
                    x: CGFloat(
                        rng.next(
                            in: Double(xRange.lowerBound)...Double(xRange.lowerBound + edgeBandX))),
                    y: CGFloat(rng.next(in: Double(yRange.lowerBound)...Double(yRange.upperBound)))
                )
            } else {
                point = CGPoint(
                    x: CGFloat(
                        rng.next(
                            in: Double(xRange.upperBound - edgeBandX)...Double(xRange.upperBound))),
                    y: CGFloat(rng.next(in: Double(yRange.lowerBound)...Double(yRange.upperBound)))
                )
            }

            let frame = CGRect(
                x: point.x - half,
                y: point.y - half,
                width: side,
                height: side
            )
            if !frame.intersects(forbiddenRect) {
                return point
            }
        }

        return CGPoint(
            x: half + 16,
            y: bounds.height - half - 16
        )
    }

    private func makeTintedShapeLayer(image: CGImage, frame: CGRect, tint: CGColor) -> CALayer {
        let root = CALayer()
        root.bounds = frame
        root.opacity = 1.0
        root.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0

        let fillLayer = CALayer()
        fillLayer.frame = root.bounds
        fillLayer.backgroundColor = tint
        fillLayer.opacity = 1.0

        let maskLayer = CALayer()
        maskLayer.frame = root.bounds
        maskLayer.contents = image
        maskLayer.contentsGravity = .resizeAspect
        maskLayer.contentsScale = root.contentsScale

        fillLayer.mask = maskLayer
        root.addSublayer(fillLayer)
        return root
    }

    private func startTimersIfNeeded() {
        guard window != nil else { return }
        if backgroundTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            // 0.7 fps = 1.0 / 0.7 ~= 1.428s
            timer.schedule(deadline: .now(), repeating: 1.0 / 0.7)
            timer.setEventHandler { [weak self] in
                self?.tickBackground()
            }
            timer.resume()
            backgroundTimer = timer
        }
        if shapeTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: 1.0 / 6.0)
            timer.setEventHandler { [weak self] in
                self?.tickShapes()
            }
            timer.resume()
            shapeTimer = timer
        }
        if dotTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            // 15fps for smooth dots
            timer.schedule(deadline: .now(), repeating: 1.0 / 15.0)
            timer.setEventHandler { [weak self] in
                self?.tickDotAnimation()
            }
            timer.resume()
            dotTimer = timer
        }
        if autoTransitionTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 15.0, repeating: 15.0)
            timer.setEventHandler { [weak self] in
                self?.tickAutoTransition()
            }
            timer.resume()
            autoTransitionTimer = timer
        }
    }

    private func stopTimers() {
        backgroundTimer?.cancel()
        backgroundTimer = nil
        shapeTimer?.cancel()
        shapeTimer = nil
        dotTimer?.cancel()
        dotTimer = nil
        autoTransitionTimer?.cancel()
        autoTransitionTimer = nil
        stopTransitionTimer()
    }

    private func startTransitionTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + (1.0 / 6.0), repeating: 1.0 / 6.0)
        timer.setEventHandler { [weak self] in
            self?.tickTransitionMask()
        }
        timer.resume()
        transitionTimer = timer
    }

    private func stopTransitionTimer() {
        transitionTimer?.cancel()
        transitionTimer = nil
    }

    private func tickBackground() {
        guard !assets.backgrounds.isEmpty else { return }
        backgroundPhase &+= 1
        applyCurrentBackgroundPhase()
    }

    private func updateDotGradient(_ container: Container) {
        guard let gradient = container.dotGradient, !palette.isEmpty else { return }

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let colors = normalizedPaletteColors(from: palette).map {
            applyBackgroundTone($0, mode: isDark ? .dark : .light).cgColor
        }

        // Simple linear gradient from palette (Tone mapped)
        gradient.colors = [
            colors[0],
            colors[1],
            colors[2],
        ]

        // Initial dot color update (will be overridden by per-round random)
        if container.dotRoot != nil {
            if container.dotColor == nil {
                assignRandomDotColor(to: container, with: palette)
            }
        }
    }

    private func assignRandomDotColor(to container: Container, with palette: [CGColor]) {
        guard !palette.isEmpty else { return }

        // Pick a random color from palette
        let rawColor = palette.randomElement() ?? palette[0]
        let nsColor = NSColor(cgColor: rawColor) ?? .white
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        // Apply FG Tone mapping for Dots
        let finalColor = applyForegroundTone(nsColor, mode: isDark ? .dark : .light)

        // Dot opacity was 0.9 previously, maintain it via color alpha if needed,
        // but tone mapping returns alpha 1.0. Let's adjust alpha here.
        let colorWithAlpha = finalColor.withAlphaComponent(0.90)

        container.dotColor = colorWithAlpha.cgColor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for dot in container.dotCells {
            dot.fillColor = container.dotColor
        }
        CATransaction.commit()
    }

    // MARK: - Tone Mapping Helpers

    private func tickAutoTransition() {
        let seed = nextTransitionSeed()
        triggerTransition(seed: seed)
    }

    private func applyCurrentBackgroundPhase() {
        applyBackgroundPhase(to: fromContainer)
        applyBackgroundPhase(to: toContainer)
    }

    private func applyBackgroundPhase(to container: Container?) {
        guard let container else { return }

        if container.style == .dot {
            // For dot style, ensure backgroundLayer is clean'ish
            container.backgroundLayer.contents = nil
            container.backgroundLayer.backgroundColor = NSColor.black.cgColor
            // Update gradient colors if palette changed
            updateDotGradient(container)
            // Ensure dot color is set initially
            if container.dotRoot != nil {
                assignRandomDotColor(to: container, with: palette)
            }
            return
        }

        // If image style, ensure tint layer is visible
        container.backgroundTintLayer?.isHidden = false

        let source = !tintedBackgrounds.isEmpty ? tintedBackgrounds : assets.backgrounds
        guard !source.isEmpty else { return }
        let image = source[backgroundPhase % source.count]
        container.backgroundLayer.contentsGravity = .resizeAspectFill
        container.backgroundLayer.contentsScale =
            window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        container.backgroundLayer.contents = image
    }

    private func tickShapes() {
        updateShapes(for: fromContainer)
        updateShapes(for: toContainer)
    }

    private func tickDotAnimation() {
        tickDotBackground(for: fromContainer)
        tickDotBackground(for: toContainer)
    }

    private func updateShapes(for container: Container?) {
        guard let container else { return }
        guard !container.shapeLayers.isEmpty else { return }
        guard container.shapeLayers.count == container.shapeStates.count else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let dt: CGFloat = 1.0 / 6.0
        for index in container.shapeLayers.indices {
            var state = container.shapeStates[index]
            state.phase += state.phaseSpeed * dt
            state.angle += state.angularSpeed * dt

            let x = state.basePosition.x + cos(state.phase) * state.driftX
            let y = state.basePosition.y + sin(state.phase * 0.93) * state.driftY

            let layer = container.shapeLayers[index]
            layer.position = CGPoint(x: x, y: y)
            layer.transform = CATransform3DMakeRotation(state.angle, 0, 0, 1)

            container.shapeStates[index] = state
        }

        CATransaction.commit()
    }

    private func tickTransitionMask() {
        guard let toContainer, let maskLayer = transitionMaskLayer else { return }
        let maskFrames = resolvedMaskFrames()
        guard !maskFrames.isEmpty else {
            finalizeTransition()
            return
        }

        maskFrameIndex += 1
        if maskFrameIndex >= maskFrames.count {
            finalizeTransition()
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.contents = maskFrames[maskFrameIndex]
        CATransaction.commit()

        toContainer.layer.mask = maskLayer
    }

    private func finalizeTransition() {
        guard let next = toContainer else {
            stopTransitionTimer()
            return
        }
        next.layer.mask = nil
        transitionMaskLayer = nil
        fromContainer?.layer.removeFromSuperlayer()
        fromContainer = next
        toContainer = nil
        stopTransitionTimer()
    }

    private func makeTintedBackgrounds(from source: [CGImage], palette: [CGColor]) -> [CGImage] {
        guard !source.isEmpty else { return [] }
        let colors = normalizedPaletteColors(from: palette)
        let mapImage = makeColorMapImage(colors: colors)

        return source.compactMap { image in
            let input = CIImage(cgImage: image)
            let grayscale = input.applyingFilter(
                "CIColorControls",
                parameters: [
                    kCIInputSaturationKey: 0.0,
                    kCIInputContrastKey: 1.0,
                    kCIInputBrightnessKey: 0.0,
                ]
            )
            guard let mapImage else { return nil }

            let mapped = grayscale.applyingFilter(
                "CIColorMap",
                parameters: ["inputGradientImage": mapImage]
            )
            return ciContext.createCGImage(mapped, from: mapped.extent)
        }
    }

    private func normalizedPaletteColors(from colors: [CGColor]) -> [NSColor] {
        let base = colors.compactMap { NSColor(cgColor: $0)?.usingColorSpace(.deviceRGB) }
        let fallback = BKArtBackgroundView.fallbackPalette
        let merged = (base + fallback)

        var output: [NSColor] = []
        for color in merged {
            output.append(color)
            if output.count == 3 { break }
        }

        while output.count < 3 {
            output.append(fallback[output.count % fallback.count])
        }

        let dark = output[0].blended(withFraction: 0.30, of: .black) ?? output[0]
        let mid = output[1]
        let light = output[2].blended(withFraction: 0.28, of: .white) ?? output[2]
        return [dark, mid, light]
    }

    private func makeColorMapImage(colors: [NSColor]) -> CIImage? {
        let width = 256
        let height = 1
        let bytesPerPixel = 4
        var data = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        let c0 = colors[0].usingColorSpace(.deviceRGB) ?? colors[0]
        let c1 = colors[1].usingColorSpace(.deviceRGB) ?? colors[1]
        let c2 = colors[2].usingColorSpace(.deviceRGB) ?? colors[2]

        for x in 0..<width {
            let t = CGFloat(x) / CGFloat(width - 1)
            let color: NSColor
            if t < 0.5 {
                let localT = t / 0.5
                color = blend(c0, c1, t: localT)
            } else {
                let localT = (t - 0.5) / 0.5
                color = blend(c1, c2, t: localT)
            }

            let rgb = color.usingColorSpace(.deviceRGB) ?? color
            let idx = x * bytesPerPixel
            data[idx + 0] = UInt8(clamp(rgb.redComponent) * 255.0)
            data[idx + 1] = UInt8(clamp(rgb.greenComponent) * 255.0)
            data[idx + 2] = UInt8(clamp(rgb.blueComponent) * 255.0)
            data[idx + 3] = 255
        }

        guard
            let provider = CGDataProvider(data: NSData(bytes: &data, length: data.count)),
            let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * bytesPerPixel,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        else { return nil }
        return CIImage(cgImage: cgImage)
    }

    private func blend(_ lhs: NSColor, _ rhs: NSColor, t: CGFloat) -> NSColor {
        let lt = lhs.usingColorSpace(.deviceRGB) ?? lhs
        let rt = rhs.usingColorSpace(.deviceRGB) ?? rhs
        let p = max(0, min(1, t))
        return NSColor(
            calibratedRed: lt.redComponent + (rt.redComponent - lt.redComponent) * p,
            green: lt.greenComponent + (rt.greenComponent - lt.greenComponent) * p,
            blue: lt.blueComponent + (rt.blueComponent - lt.blueComponent) * p,
            alpha: 1.0
        )
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(1.0, max(0.0, value))
    }

    private func nextTransitionSeed() -> UInt64 {
        transitionSeedCounter &+= 1
        return rebuildSeed &+ (transitionSeedCounter &* 0x9E37_79B9_7F4A_7C15)
    }

    private var expandedBounds: CGRect {
        bounds.insetBy(dx: -1.0, dy: -1.0)
    }

    private func resolvedMaskFrames() -> [CGImage] {
        if !processedMaskFrames.isEmpty {
            return processedMaskFrames
        }
        processedMaskFrames = assets.maskFrames.compactMap { convertedMaskFrame(from: $0) ?? $0 }
        return processedMaskFrames
    }

    private func convertedMaskFrame(from image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let alphaMask = input.applyingFilter("CIMaskToAlpha")
        return ciContext.createCGImage(alphaMask, from: alphaMask.extent)
    }

    private static func paletteSignature(for colors: [CGColor]) -> String {
        colors
            .map { color in
                let c = NSColor(cgColor: color)?.usingColorSpace(.deviceRGB) ?? NSColor.white
                return String(
                    format: "%.4f_%.4f_%.4f_%.4f",
                    c.redComponent,
                    c.greenComponent,
                    c.blueComponent,
                    c.alphaComponent
                )
            }
            .joined(separator: "|")
    }

    // MARK: - Dot Background Implementation

    private func setupDotBackground(in container: Container, rng: inout BKSeededRandom) {
        let root = CALayer()
        root.frame = expandedBounds
        root.masksToBounds = true
        container.dotRoot = root
        container.layer.insertSublayer(root, above: container.backgroundLayer)

        // A) Gradient Background
        let gradient = CAGradientLayer()
        gradient.frame = root.bounds
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        container.dotGradient = gradient
        root.addSublayer(gradient)
        updateDotGradient(container)

        // B) Dot Pattern
        // Larger dots, slightly more spacing
        let baseSize = max(bounds.width, bounds.height)
        let dotSpacing: CGFloat = 30  // Increased from 24
        let cols = Int(baseSize / dotSpacing) + 6
        let rows = Int(baseSize / dotSpacing) + 6

        // Grid 1: Larger dots (Center) - High opacity
        let grid1 = CALayer()
        grid1.frame = root.bounds
        let dot1 = addDotGrid(
            to: grid1, cols: cols, rows: rows, spacing: dotSpacing, radius: 4.2, opacity: 0.90)
        root.addSublayer(grid1)

        // Grid 2: Smaller dots (Edges) - Lower opacity
        let grid2 = CALayer()
        grid2.frame = root.bounds
        let dot2 = addDotGrid(
            to: grid2, cols: cols, rows: rows, spacing: dotSpacing, radius: 2.5, opacity: 0.50)
        root.addSublayer(grid2)

        container.dotCells = [dot1, dot2]

        // C) Masks
        // mask1 for grid1 (Big): Will have smaller radius, so big dots disappear first
        // mask2 for grid2 (Small): Will have larger radius, so small dots persist longer
        let mask1 = CAShapeLayer()
        mask1.fillColor = NSColor.black.cgColor

        let mask2 = CAShapeLayer()
        mask2.fillColor = NSColor.black.cgColor

        grid1.mask = mask1
        grid2.mask = mask2

        container.dotMasks = [mask1, mask2]

        // Setup Animation State (Starts totally Off-screen)
        let r = baseSize * 0.30
        let start = randomOffscreenPoint(radius: r, rng: &rng)
        let end = randomOffscreenPoint(radius: r, rng: &rng)

        let cp1 = CGPoint(
            x: rng.next(in: Double(bounds.minX)...Double(bounds.maxX)),
            y: rng.next(in: Double(bounds.minY)...Double(bounds.maxY))
        )
        let cp2 = CGPoint(
            x: rng.next(in: Double(bounds.minX)...Double(bounds.maxX)),
            y: rng.next(in: Double(bounds.minY)...Double(bounds.maxY))
        )

        container.dotAnim = DotAnimState(
            motion: .moving(0.0),
            start: start,
            cp1: cp1,
            cp2: cp2,
            end: end,
            duration: 12.0
        )
    }

    @discardableResult
    private func addDotGrid(
        to parent: CALayer, cols: Int, rows: Int, spacing: CGFloat, radius: CGFloat, opacity: Float,
        offset: CGPoint = .zero
    ) -> CAShapeLayer {
        let dot = CAShapeLayer()
        dot.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        dot.path = CGPath(ellipseIn: dot.bounds, transform: nil)
        // Default color, dark grey from palette to avoid white flash
        dot.fillColor = NSColor(white: 0.3, alpha: 1.0).cgColor
        dot.opacity = opacity

        let repX = CAReplicatorLayer()
        repX.instanceCount = cols
        repX.instanceTransform = CATransform3DMakeTranslation(spacing, 0, 0)
        repX.addSublayer(dot)

        let repY = CAReplicatorLayer()
        repY.instanceCount = rows
        repY.instanceTransform = CATransform3DMakeTranslation(0, spacing, 0)
        repY.addSublayer(repX)

        repY.position = CGPoint(x: -spacing * 2 + offset.x, y: -spacing * 2 + offset.y)
        parent.addSublayer(repY)

        return dot
    }

    private func tickDotBackground(for container: Container?) {
        guard let container, container.style == .dot,
            let anim = container.dotAnim,
            !container.dotMasks.isEmpty
        else { return }

        // 15fps timer triggers this.
        let dt = 1.0 / 15.0

        switch anim.motion {
        case .idle(let remaining):
            let next = remaining - dt
            if next <= 0 {
                // Generate new path with seeded random
                // We use a simple hash of current end point to seed the next path to keep it deterministic-ish
                let seed = UInt64(bitPattern: Int64(anim.end.x * 100 + anim.end.y))
                var rng = BKSeededRandom(seed: seed ^ 0x1234_5678)

                startNewDotRun(container: container, rng: &rng)
                // startNewDotRun updates container.dotAnim
            } else {
                container.dotAnim?.motion = .idle(next)
                return
            }

        case .moving(let t):
            // Advance
            let step = dt / anim.duration
            var nextT = t + step

            if nextT >= 1.0 {
                // Completed, switch to idle
                let wait = Double.random(in: 0.25...0.45)
                container.dotAnim?.motion = .idle(wait)
                nextT = 1.0
            } else {
                container.dotAnim?.motion = .moving(nextT)
            }

            // Calculate visual
            let pos = cubicBezier(
                t: nextT, p0: anim.start, p1: anim.cp1, p2: anim.cp2, p3: anim.end)

            // Radius/Scale logic:
            // Enter (0..0.25): 0.6 -> 1.0
            // Exit (0.8..1.0): 1.0 -> 0.6
            var scale: CGFloat = 1.0
            if nextT < 0.25 {
                let localT = nextT / 0.25
                scale = 0.6 + 0.4 * easeOutQuint(localT)
            } else if nextT > 0.8 {
                let localT = (nextT - 0.8) / 0.2
                scale = 1.0 - 0.4 * easeInQuint(localT)
            }

            // Use randomized base radius
            let baseR =
                (container.dotBaseRadius > 0
                    ? container.dotBaseRadius : max(bounds.width, bounds.height) * 0.30)
            let currentR = baseR * scale

            CATransaction.begin()
            CATransaction.setDisableActions(true)

            if container.dotMasks.count >= 2 {
                // Mask 0 (Big dots): 75% radius
                let r0 = currentR * 0.75
                let rect0 = CGRect(x: pos.x - r0, y: pos.y - r0, width: r0 * 2, height: r0 * 2)
                container.dotMasks[0].path = CGPath(ellipseIn: rect0, transform: nil)

                // Mask 1 (Small dots): 100% radius (fading edge)
                let r1 = currentR
                let rect1 = CGRect(x: pos.x - r1, y: pos.y - r1, width: r1 * 2, height: r1 * 2)
                container.dotMasks[1].path = CGPath(ellipseIn: rect1, transform: nil)
            }

            CATransaction.commit()
        }
    }

    private func startNewDotRun(container: Container, rng: inout BKSeededRandom) {
        let r = max(bounds.width, bounds.height) * 0.30
        let start = randomOffscreenPoint(radius: r, rng: &rng)
        let end = randomOffscreenPoint(radius: r, rng: &rng)

        let c1 = CGPoint(
            x: rng.next(in: Double(bounds.minX)...Double(bounds.maxX)),
            y: rng.next(in: Double(bounds.minY)...Double(bounds.maxY))
        )
        let c2 = CGPoint(
            x: rng.next(in: Double(bounds.minX)...Double(bounds.maxX)),
            y: rng.next(in: Double(bounds.minY)...Double(bounds.maxY))
        )

        // Randomized Sizes per run
        // Base Radius: 0.26 ... 0.34
        let baseSize = max(bounds.width, bounds.height)
        container.dotBaseRadius = baseSize * CGFloat(rng.next(in: 0.26...0.34))

        // Dot Sizes
        container.dotRadiusLarge = CGFloat(rng.next(in: 5.0...6.2))
        container.dotRadiusSmall = CGFloat(rng.next(in: 3.0...4.0))

        // Randomize Color for this run
        self.assignRandomDotColor(to: container, with: self.palette)

        var anim =
            container.dotAnim
            ?? DotAnimState(
                motion: .moving(0), start: .zero, cp1: .zero, cp2: .zero, end: .zero, duration: 12)
        anim.start = start
        anim.end = end
        anim.cp1 = c1
        anim.cp2 = c2
        anim.motion = .moving(0.0)
        container.dotAnim = anim

        // Update Dot Shapes (Path) for new sizes
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if container.dotCells.count >= 2 {
            let dot1 = container.dotCells[0]
            let r1 = container.dotRadiusLarge
            dot1.path = CGPath(
                ellipseIn: CGRect(x: 0, y: 0, width: r1 * 2, height: r1 * 2), transform: nil)
            dot1.bounds = CGRect(x: 0, y: 0, width: r1 * 2, height: r1 * 2)

            let dot2 = container.dotCells[1]
            let r2 = container.dotRadiusSmall
            dot2.path = CGPath(
                ellipseIn: CGRect(x: 0, y: 0, width: r2 * 2, height: r2 * 2), transform: nil)
            dot2.bounds = CGRect(x: 0, y: 0, width: r2 * 2, height: r2 * 2)
        }
        CATransaction.commit()
    }

    private func cubicBezier(t: Double, p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint)
        -> CGPoint
    {
        let oneMinusT = 1.0 - t
        let t2 = t * t
        let t3 = t2 * t
        let oneMinusT2 = oneMinusT * oneMinusT
        let oneMinusT3 = oneMinusT2 * oneMinusT

        let x =
            oneMinusT3 * p0.x + 3 * oneMinusT2 * t * p1.x + 3 * oneMinusT * t2 * p2.x + t3 * p3.x
        let y =
            oneMinusT3 * p0.y + 3 * oneMinusT2 * t * p1.y + 3 * oneMinusT * t2 * p2.y + t3 * p3.y
        return CGPoint(x: x, y: y)
    }

    private func easeOutQuint(_ x: Double) -> Double {
        return 1.0 - pow(1.0 - x, 5)
    }

    private func easeInQuint(_ x: Double) -> Double {
        return x * x * x * x * x
    }

    private func randomOffscreenPoint(radius: CGFloat, rng: inout BKSeededRandom) -> CGPoint {
        // Pick a side: 0=top, 1=bottom, 2=left, 3=right
        let side = rng.nextInt(in: 0...3)
        // Explicitly force far offscreen.
        // If center is here, and radius is r. To be fully offscreen, center needs to be > r away from edge.
        // Let's go 1.5 * r just to be safe and "slowly enter"
        let margin = radius * 1.5

        switch side {
        case 0:  // Top
            return CGPoint(
                x: CGFloat(
                    rng.next(in: Double(bounds.minX - margin)...Double(bounds.maxX + margin))),
                y: bounds.maxY + margin
            )
        case 1:  // Bottom
            return CGPoint(
                x: CGFloat(
                    rng.next(in: Double(bounds.minX - margin)...Double(bounds.maxX + margin))),
                y: bounds.minY - margin
            )
        case 2:  // Left
            return CGPoint(
                x: bounds.minX - margin,
                y: CGFloat(
                    rng.next(in: Double(bounds.minY - margin)...Double(bounds.maxY + margin)))
            )
        default:  // Right
            return CGPoint(
                x: bounds.maxX + margin,
                y: CGFloat(
                    rng.next(in: Double(bounds.minY - margin)...Double(bounds.maxY + margin)))
            )
        }
    }

    private enum ToneMode {
        case dark
        case light
    }

    private func applyBackgroundTone(_ color: NSColor, mode: ToneMode) -> NSColor {
        // Uniform desaturation
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        color.usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        // s *= 0.65~0.80 -> 0.70
        let newS = s * 0.70
        var newB = b

        if mode == .dark {
            // Dark: clamp b to 0.35~0.55 if possible, then limit max
            // Logic: b = min(b, 0.55) * 0.85
            newB = min(b, 0.55) * 0.85
        } else {
            // Light: Lift floor, Cap ceiling.
            // b = min(max(b, 0.60), 0.85)
            newB = min(max(b, 0.60), 0.85)
        }
        return NSColor(hue: h, saturation: newS, brightness: newB, alpha: 1.0)
    }

    private func applyForegroundTone(_ color: NSColor, mode: ToneMode) -> NSColor {
        // Shapes & Dots
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        color.usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        // Moderate saturation
        let newS = min(s, 0.85)
        var newB = b

        if mode == .dark {
            // Dark mode: FG should be brighter than BG
            // b >= 0.65
            newB = max(b, 0.65)
            // Cap at 0.92 to avoid glare
            newB = min(newB, 0.92)
        } else {
            // Light mode: FG should be darker than BG
            // b <= 0.70
            newB = min(b, 0.70)
            // Floor at 0.3 to ensure visibility
            newB = max(newB, 0.30)
        }
        return NSColor(hue: h, saturation: newS, brightness: newB, alpha: 1.0)
    }
}

private struct BKSeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0xD1B5_4A32_9C7E_44F1 : seed
    }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        let unit = Double(nextUInt64() >> 11) / Double((1 << 53) - 1)
        return range.lowerBound + (range.upperBound - range.lowerBound) * unit
    }

    mutating func next(in range: Range<Double>) -> Double {
        let unit = Double(nextUInt64() >> 11) / Double((1 << 53) - 1)
        return range.lowerBound + (range.upperBound - range.lowerBound) * unit
    }

    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        let low = range.lowerBound
        let high = range.upperBound
        guard high >= low else { return low }
        let span = high - low + 1
        return low + Int(nextUInt64() % UInt64(span))
    }

    mutating func nextBool() -> Bool {
        (nextUInt64() & 1) == 0
    }
}

extension Array {
    fileprivate mutating func shuffle(using generator: inout BKSeededRandom) {
        guard count > 1 else { return }
        for index in indices.dropLast() {
            let remaining = count - index
            let offset = Int(generator.next(in: 0..<Double(remaining)))
            swapAt(index, index + offset)
        }
    }
}

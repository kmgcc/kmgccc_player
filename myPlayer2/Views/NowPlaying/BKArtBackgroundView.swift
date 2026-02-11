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

    func makeNSView(context: Context) -> BKArtBackgroundLayerView {
        let view = BKArtBackgroundLayerView()
        view.updatePalette(palette)
        view.ensureBaseContainer(seed: seed)
        view.currentTransitionID = transitionID
        return view
    }

    func updateNSView(_ nsView: BKArtBackgroundLayerView, context: Context) {
        nsView.updatePalette(palette)
        nsView.ensureBaseContainer(seed: seed)

        if nsView.currentTransitionID != transitionID {
            nsView.currentTransitionID = transitionID
            nsView.triggerTransition(seed: seed &+ UInt64(truncatingIfNeeded: transitionID))
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

    private final class Container {
        let layer = CALayer()
        let backgroundLayer = CALayer()
        var shapeLayers: [CALayer] = []
        var shapeStates: [ShapeState] = []

        init(frame: CGRect) {
            layer.frame = frame
            layer.masksToBounds = true
            backgroundLayer.frame = frame
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

    private var fromContainer: Container?
    private var toContainer: Container?
    private var transitionMaskLayer: CALayer?

    private var backgroundPhase: Int = 0
    private var maskFrameIndex: Int = 0
    private var lastLayoutSize: CGSize = .zero
    private var rebuildSeed: UInt64 = 0

    private var backgroundTimer: DispatchSourceTimer?
    private var shapeTimer: DispatchSourceTimer?
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

        if fromContainer == nil {
            ensureBaseContainer(seed: rebuildSeed)
        }

        if lastLayoutSize == .zero {
            lastLayoutSize = bounds.size
        } else if abs(lastLayoutSize.width - bounds.width) > 4 || abs(lastLayoutSize.height - bounds.height) > 4 {
            lastLayoutSize = bounds.size
            rebuildForCurrentBounds()
            return
        }

        layoutContainer(fromContainer)
        layoutContainer(toContainer)
        transitionMaskLayer?.frame = bounds
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

        guard !assets.maskFrames.isEmpty else {
            finalizeTransition()
            return
        }

        let mask = CALayer()
        mask.frame = bounds
        mask.contentsGravity = .resizeAspectFill
        mask.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        mask.contents = assets.maskFrames[0]
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
        container.layer.frame = bounds
        container.backgroundLayer.frame = bounds
        container.backgroundLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    }

    private func buildContainer(seed: UInt64) -> Container {
        let container = Container(frame: bounds)
        var rng = BKSeededRandom(seed: seed == 0 ? 0xA17D_4C59_10F3_778D : seed)

        let count = rng.nextInt(in: 10...16)
        let chosenShapes = chooseShapeImages(count: count, rng: &rng)
        let forbiddenRect = CGRect(
            x: bounds.width * 0.28,
            y: bounds.height * 0.22,
            width: bounds.width * 0.44,
            height: bounds.height * 0.50
        )

        for image in chosenShapes {
            let base = min(bounds.width, bounds.height)
            let side = base * CGFloat(rng.next(in: 0.50...1.80)) * 0.22
            let shapeBounds = CGRect(x: 0, y: 0, width: side, height: side)
            let point = randomEdgePoint(
                side: side,
                forbiddenRect: forbiddenRect,
                rng: &rng
            )
            let tintColor: CGColor = {
                guard !palette.isEmpty else { return NSColor.white.cgColor }
                let idx = Int(rng.next(in: 0..<Double(palette.count)))
                return palette[min(idx, palette.count - 1)]
            }()

            let shapeLayer = makeTintedShapeLayer(
                image: image,
                frame: shapeBounds,
                tint: tintColor
            )
            shapeLayer.position = point
            shapeLayer.opacity = 1.0
            shapeLayer.transform = CATransform3DMakeRotation(CGFloat(rng.next(in: 0...(Double.pi * 2))), 0, 0, 1)
            container.layer.addSublayer(shapeLayer)

            container.shapeLayers.append(shapeLayer)
            container.shapeStates.append(
                ShapeState(
                    basePosition: point,
                    driftX: CGFloat(rng.next(in: -12...12)),
                    driftY: CGFloat(rng.next(in: -16...16)),
                    phase: CGFloat(rng.next(in: 0...(Double.pi * 2))),
                    phaseSpeed: CGFloat(rng.next(in: 0.35...0.95)),
                    angle: CGFloat(rng.next(in: 0...(Double.pi * 2))),
                    angularSpeed: CGFloat(rng.next(in: -0.22...0.22))
                )
            )
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
                    y: CGFloat(rng.next(in: Double(yRange.upperBound - edgeBandY)...Double(yRange.upperBound)))
                )
            } else if sidePick < 0.60 {
                point = CGPoint(
                    x: CGFloat(rng.next(in: Double(xRange.lowerBound)...Double(xRange.upperBound))),
                    y: CGFloat(rng.next(in: Double(yRange.lowerBound)...Double(yRange.lowerBound + edgeBandY)))
                )
            } else if sidePick < 0.80 {
                point = CGPoint(
                    x: CGFloat(rng.next(in: Double(xRange.lowerBound)...Double(xRange.lowerBound + edgeBandX))),
                    y: CGFloat(rng.next(in: Double(yRange.lowerBound)...Double(yRange.upperBound)))
                )
            } else {
                point = CGPoint(
                    x: CGFloat(rng.next(in: Double(xRange.upperBound - edgeBandX)...Double(xRange.upperBound))),
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
            timer.schedule(deadline: .now(), repeating: 1.0)
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
        autoTransitionTimer?.cancel()
        autoTransitionTimer = nil
        stopTransitionTimer()
    }

    private func startTransitionTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 6.0)
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
        guard !assets.maskFrames.isEmpty else {
            finalizeTransition()
            return
        }

        maskFrameIndex += 1
        if maskFrameIndex >= assets.maskFrames.count {
            finalizeTransition()
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.contents = assets.maskFrames[maskFrameIndex]
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

private extension Array {
    mutating func shuffle(using generator: inout BKSeededRandom) {
        guard count > 1 else { return }
        for index in indices.dropLast() {
            let remaining = count - index
            let offset = Int(generator.next(in: 0..<Double(remaining)))
            swapAt(index, index + offset)
        }
    }
}

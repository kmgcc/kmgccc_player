//
//  BKArtBackgroundView.swift
//  myPlayer2
//
//  Now Playing artistic background:
//  - bk1/bk2 cycling at 3fps
//  - 5~6 opaque random tinted shapes
//  - transition via 6fps luma mask
//

import AppKit
import Combine
import QuartzCore
import SwiftUI

private enum BKArtDebugOptions {
    // Debug verification toggles (default ON for定位):
    // A) Force symbol into backgroundLayer.contents to verify contents链路。
    static let forceSymbol = false
    // B) Disable all mask assignment to verify base images/shapes visibility.
    static let disableMask = false
}

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
        .onChange(of: artworkData?.count) { _, _ in
            refreshPalette()
        }
    }

    private var seedValue: UInt64 {
        guard let id = trackID else { return 0xA17D_4C59_10F3_778D }
        return UInt64(bitPattern: Int64(id.uuidString.hashValue))
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
    private let debugBackgroundCGImage = BKArtBackgroundLayerView.makeDebugSymbolImage()

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
        palette = colors.map { ($0.usingColorSpace(.deviceRGB) ?? $0).cgColor }
    }

    func ensureBaseContainer(seed: UInt64) {
        rebuildSeed = seed
        guard fromContainer == nil, !bounds.isEmpty else { return }
        let container = buildContainer(seed: seed)
        fromContainer = container
        layer?.addSublayer(container.layer)
        #if DEBUG
            print("[BKArt] ensureBaseContainer addSublayer fromContainer, frame=\(container.layer.frame)")
        #endif
        applyCurrentBackgroundPhase()
        startTimersIfNeeded()
    }

    func triggerTransition(seed: UInt64) {
        guard !bounds.isEmpty else { return }
        rebuildSeed = seed
        ensureBaseContainer(seed: seed)
        guard let current = fromContainer else { return }

        stopTransitionTimer()
        let next = buildContainer(seed: seed ^ 0x9E37_79B9_7F4A_7C15)
        toContainer = next
        layer?.insertSublayer(next.layer, above: current.layer)
        #if DEBUG
            print("[BKArt] triggerTransition insert toContainer above fromContainer")
        #endif
        applyBackgroundPhase(to: next)

        guard !BKArtDebugOptions.disableMask else {
            current.layer.removeFromSuperlayer()
            fromContainer = next
            toContainer = nil
            transitionMaskLayer = nil
            return
        }

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
        #if DEBUG
            print(
                "[BKArt] mask attach -> to=\(next.layer.frame), mask=\(mask.frame), contentsNil=\(mask.contents == nil)")
        #endif
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

        let count = rng.nextBool() ? 5 : 6
        let chosenShapes = chooseShapeImages(count: count, rng: &rng)
        let forbiddenRect = CGRect(
            x: bounds.width * 0.28,
            y: bounds.height * 0.22,
            width: bounds.width * 0.44,
            height: bounds.height * 0.50
        )

        for image in chosenShapes {
            let base = min(bounds.width, bounds.height)
            let side = base * CGFloat(rng.next(in: 0.25...1.2)) * 0.24
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

        if BKArtDebugOptions.disableMask {
            // Debug B: keep shapes visible without any mask usage.
            fillLayer.contents = image
            fillLayer.contentsGravity = .resizeAspect
            fillLayer.contentsScale = root.contentsScale
            fillLayer.backgroundColor = nil
        } else {
            fillLayer.mask = maskLayer
        }
        root.addSublayer(fillLayer)
        return root
    }

    private func startTimersIfNeeded() {
        guard window != nil else { return }
        if backgroundTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: 1.0 / 3.0)
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
    }

    private func stopTimers() {
        backgroundTimer?.cancel()
        backgroundTimer = nil
        shapeTimer?.cancel()
        shapeTimer = nil
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

    private func applyCurrentBackgroundPhase() {
        applyBackgroundPhase(to: fromContainer)
        applyBackgroundPhase(to: toContainer)
    }

    private func applyBackgroundPhase(to container: Container?) {
        guard let container else { return }
        let image: CGImage? = {
            if BKArtDebugOptions.forceSymbol {
                return debugBackgroundCGImage
            }
            guard !assets.backgrounds.isEmpty else { return nil }
            return assets.backgrounds[backgroundPhase % assets.backgrounds.count]
        }()
        guard let image else { return }
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
        guard !BKArtDebugOptions.disableMask else { return }
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
        if !BKArtDebugOptions.disableMask {
            next.layer.mask = nil
        }
        transitionMaskLayer = nil
        fromContainer?.layer.removeFromSuperlayer()
        fromContainer = next
        toContainer = nil
        stopTransitionTimer()
    }

    private static func makeDebugSymbolImage() -> CGImage? {
        if let symbol = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil) {
            let canvasSize = NSSize(width: 512, height: 512)
            let canvas = NSImage(size: canvasSize)
            canvas.lockFocus()
            NSColor.systemYellow.setFill()
            let rect = NSRect(x: 96, y: 96, width: 320, height: 320)
            symbol.draw(in: rect)
            canvas.unlockFocus()
            if let cg = canvas.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                return cg
            }
        }

        let width = 256
        let height = 256
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.setFillColor(NSColor.systemPink.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
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

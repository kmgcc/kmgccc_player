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
    let isPlaying: Bool
    @Environment(\.colorScheme) private var colorScheme

    @State private var palette: [NSColor] = Self.fallbackPalette

    var body: some View {
        BKArtBackgroundRepresentable(
            transitionID: controller.transitionID,
            seed: seedValue,
            palette: palette,
            isDark: colorScheme == .dark,
            isPlaying: isPlaying
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
        let base = ArtworkColorExtractor.uiThemePalette(from: data, maxColors: 4)
        let rich = ArtworkColorExtractor.uiThemePaletteRich(from: data, desiredCount: 8)
        let chosen = rich.isEmpty ? base : rich
        palette = chosen.isEmpty ? Self.fallbackPalette : chosen
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
    let isDark: Bool
    let isPlaying: Bool

    func makeNSView(context: Context) -> BKArtBackgroundLayerView {
        let contentView = BKArtBackgroundLayerView()
        contentView.updatePalette(palette, isDark: isDark)
        contentView.ensureBaseContainer(seed: seed)
        contentView.setPlayback(isPlaying: isPlaying)
        contentView.currentTransitionID = transitionID
        return contentView
    }

    func updateNSView(_ nsView: BKArtBackgroundLayerView, context: Context) {
        nsView.updatePalette(palette, isDark: isDark)
        nsView.ensureBaseContainer(seed: seed)
        nsView.setPlayback(isPlaying: isPlaying)

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

    private struct SelectedShape {
        var image: CGImage
        var scaleMultiplier: CGFloat
        var isEdgePinned: Bool
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
        // Overlap logic
        var leadInOverlapT: Double  // e.g. 0.85, at which point next slot starts
    }

    private class DotSlot {
        let rootLayer: CALayer = CALayer()
        var maskBig: CAShapeLayer?
        var maskSmall: CAShapeLayer?
        var cellBig: CAShapeLayer?  // Reference to replicator prototype or similar if we want to change color
        var cellSmall: CAShapeLayer?

        var anim: DotAnimState
        var color: CGColor?

        var baseRadius: CGFloat
        var radiusBig: CGFloat
        var radiusSmall: CGFloat
        var maskBaseRadiusBig: CGFloat
        var maskBaseRadiusSmall: CGFloat

        init(anim: DotAnimState, baseRadius: CGFloat) {
            self.anim = anim
            self.baseRadius = baseRadius
            self.radiusBig = 0
            self.radiusSmall = 0
            self.maskBaseRadiusBig = max(1, baseRadius * 0.75)
            self.maskBaseRadiusSmall = max(1, baseRadius)
        }
    }

    private final class Container {
        let layer = CALayer()
        let backgroundLayer = CALayer()
        let backgroundToneLayer = CALayer()
        let shapesRoot = CALayer()

        var style: BackgroundStyle = .image
        var dotRoot: CALayer?
        var dotGradient: CAGradientLayer?

        // Multi-slot support for overlapping dot windows
        var dotSlots: [DotSlot] = []

        // Removed old single-instance properties
        // var dotMasks... var dotAnim... var dotCells... var dotColor...

        var shapeLayers: [CALayer] = []
        var shapeStates: [ShapeState] = []
        var shapeTints: [CGColor] = []
        var shapeSwatches: [CGColor] = []
        var swatchDiagnostics: BKColorEngine.ShapeSwatchDiagnostics?
        var bgVariantIndex: Int = 0
        var seed: UInt64 = 0

        init(frame: CGRect) {
            layer.frame = frame
            layer.masksToBounds = true
            layer.backgroundColor = NSColor.black.cgColor

            backgroundLayer.frame = frame
            backgroundLayer.backgroundColor = NSColor.black.cgColor
            backgroundLayer.contentsGravity = .resizeAspectFill
            layer.addSublayer(backgroundLayer)

            backgroundToneLayer.frame = frame
            layer.addSublayer(backgroundToneLayer)

            shapesRoot.frame = frame
            layer.addSublayer(shapesRoot)
        }
    }

    var currentTransitionID: Int = 0

    private let assets = BKThemeAssets.shared
    private var harmonized: HarmonizedPalette = BKColorEngine.make(
        extracted: BKArtBackgroundView.fallbackPalette,
        fallback: BKArtBackgroundView.fallbackPalette,
        isDark: false
    )
    private var extractedPaletteForSwatches: [NSColor] = BKArtBackgroundView.fallbackPalette
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var tintedBackgroundVariants: [[CGImage]] = []
    private var paletteSignature: String = ""
    private var fromContainer: Container?
    private var toContainer: Container?
    private var transitionMaskLayer: CALayer?

    private var backgroundPhase: Int = 0
    private var backgroundPhaseFloat: Double = 0
    private var maskFrameIndex: Int = 0
    private var maskFrameProgress: Double = 0
    private var lastLayoutSize: CGSize = .zero
    private var rebuildSeed: UInt64 = 0

    private var backgroundTimer: DispatchSourceTimer?
    private var shapeTimer: DispatchSourceTimer?
    private var dotTimer: DispatchSourceTimer?
    private var transitionTimer: DispatchSourceTimer?
    private var autoTransitionTimer: DispatchSourceTimer?
    private var speedRampTimer: DispatchSourceTimer?
    private var transitionSeedCounter: UInt64 = 0
    private var speedCurrent: Double = 1.0
    private var speedTarget: Double = 1.0
    private var lastTickTime: CFTimeInterval = CACurrentMediaTime()
    private var isPausedFrozen = false
    private var didPrewarmMaskFrames = false
    private var pendingBoundsRebuild = false
    private var isTransitionInFlight = false
    private var didPauseBackgroundTimerForTransition = false
    private var didPauseDotTimerForTransition = false
    private var deferredPaletteUpdate: ([NSColor], Bool)?

    // Style Selector State
    private var lastStyle: BackgroundStyle?
    private var lastStyleRunCount: Int = 0

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
        speedRampTimer?.cancel()
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
            if isTransitionInFlight || toContainer != nil {
                pendingBoundsRebuild = true
                layoutContainer(fromContainer)
                layoutContainer(toContainer)
                transitionMaskLayer?.frame = expandedBounds
                return
            }
            rebuildForCurrentBounds()
            return
        }

        layoutContainer(fromContainer)
        layoutContainer(toContainer)
        transitionMaskLayer?.frame = expandedBounds
    }

    func updatePalette(_ colors: [NSColor], isDark: Bool) {
        guard !colors.isEmpty else { return }
        let converted = colors.map { $0.usingColorSpace(.deviceRGB) ?? $0 }
        if shouldFreezeVisualUpdates {
            deferredPaletteUpdate = (converted, isDark)
            return
        }
        applyPalette(converted, isDark: isDark)
    }

    func setPlayback(isPlaying: Bool) {
        let newTarget = isPlaying ? 1.0 : 0.0
        guard newTarget != speedTarget || (isPlaying && isPausedFrozen) else { return }

        speedTarget = newTarget
        lastTickTime = CACurrentMediaTime()

        if isPlaying {
            if isPausedFrozen {
                resumeAnimationTimersAfterFreeze()
            }
            if autoTransitionTimer == nil {
                scheduleNextAutoTransition()
            }
            if let deferred = deferredPaletteUpdate {
                deferredPaletteUpdate = nil
                applyPalette(deferred.0, isDark: deferred.1)
            }
        } else {
            autoTransitionTimer?.cancel()
            autoTransitionTimer = nil
        }

        startSpeedRampTimerIfNeeded()
    }

    private func applyPalette(_ converted: [NSColor], isDark: Bool) {
        extractedPaletteForSwatches = converted
        let colorSignature = Self.paletteSignature(for: converted.map(\.cgColor))
        let signature = "\(colorSignature)|dark:\(isDark ? 1 : 0)"
        guard signature != paletteSignature else { return }

        harmonized = BKColorEngine.make(
            extracted: converted,
            fallback: BKArtBackgroundView.fallbackPalette,
            isDark: isDark
        )
        paletteSignature = signature
        tintedBackgroundVariants = makeTintedBackgroundVariants(from: assets.backgrounds)
        let toneColorForVariant: (Int) -> CGColor = { index in
            let stops = !self.harmonized.bgVariants.isEmpty
                ? self.harmonized.bgVariants[min(max(0, index), self.harmonized.bgVariants.count - 1)]
                : self.harmonized.bgStops
            return stops.first ?? (self.harmonized.isDark ? NSColor.black.cgColor : NSColor.white.cgColor)
        }
        let toneOpacity: Float = harmonized.isDark ? 0.30 : 0.18
        if let from = fromContainer {
            from.backgroundToneLayer.backgroundColor = toneColorForVariant(from.bgVariantIndex)
        }
        fromContainer?.backgroundToneLayer.opacity = toneOpacity
        if let to = toContainer {
            to.backgroundToneLayer.backgroundColor = toneColorForVariant(to.bgVariantIndex)
        }
        toContainer?.backgroundToneLayer.opacity = toneOpacity
        applyCurrentBackgroundPhase()

        if let from = fromContainer { updateDotGradient(from) }
        if let to = toContainer { updateDotGradient(to) }

        retintShapes(in: fromContainer)
        retintShapes(in: toContainer)
    }

    func ensureBaseContainer(seed: UInt64) {
        rebuildSeed = seed
        guard fromContainer == nil, !bounds.isEmpty else { return }
        if tintedBackgroundVariants.isEmpty {
            tintedBackgroundVariants = makeTintedBackgroundVariants(from: assets.backgrounds)
        }
        prewarmTransitionAssetsIfNeeded()
        let container = buildContainer(seed: seed)
        // Ensure initial container respects style choice
        if container.style == .image && tintedBackgroundVariants.isEmpty {
            // Fallback or retry? Should be fine as applyBackgroundPhase handles empty.
        }
        fromContainer = container
        commitStyleHistory(container.style)
        layer?.addSublayer(container.layer)
        applyCurrentBackgroundPhase()
        startTimersIfNeeded()
    }

    func triggerTransition(seed: UInt64) {
        guard !bounds.isEmpty else { return }
        guard speedTarget > 0.01 else { return }
        rebuildSeed = seed
        ensureBaseContainer(seed: seed)
        guard let current = fromContainer else { return }
        guard toContainer == nil else { return }

        enterTransitionPerformanceMode(currentStyle: current.style)
        stopTransitionTimer()
        // Mix seed more aggressively
        let mixed = seed ^ 0x9E37_79B9_7F4A_7C15 ^ (UInt64(maskFrameIndex) &* 0xBF58_476D_1CE4_E5B9)
        let next = buildContainer(seed: mixed)
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
        maskFrameProgress = 0
        startTransitionTimer()
    }

    private func rebuildForCurrentBounds() {
        guard !bounds.isEmpty else { return }
        guard !isTransitionInFlight else {
            pendingBoundsRebuild = true
            return
        }
        pendingBoundsRebuild = false
        stopTransitionTimer()

        let replacement = buildContainer(seed: rebuildSeed)
        fromContainer?.layer.removeFromSuperlayer()
        toContainer?.layer.removeFromSuperlayer()
        transitionMaskLayer = nil
        fromContainer = replacement
        toContainer = nil
        commitStyleHistory(replacement.style)

        layer?.addSublayer(replacement.layer)
        applyCurrentBackgroundPhase()
        startTimersIfNeeded()
    }

    private func layoutContainer(_ container: Container?) {
        guard let container else { return }
        let layoutFrame = expandedBounds
        container.layer.frame = layoutFrame
        container.backgroundLayer.frame = layoutFrame
        container.backgroundLayer.contentsScale =
            window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        container.backgroundToneLayer.frame = layoutFrame
        container.shapesRoot.frame = layoutFrame

        if let dotRoot = container.dotRoot {
            dotRoot.frame = layoutFrame
            container.dotGradient?.frame = dotRoot.bounds

            for slot in container.dotSlots {
                slot.rootLayer.frame = dotRoot.bounds
                slot.maskBig?.frame = dotRoot.bounds
                slot.maskSmall?.frame = dotRoot.bounds
                slot.rootLayer.sublayers?.forEach { sublayer in
                    sublayer.frame = dotRoot.bounds
                }
            }
        }
    }

    private func buildContainer(seed: UInt64) -> Container {
        let container = Container(frame: bounds)
        let normalizedSeed = seed == 0 ? 0xA17D_4C59_10F3_778D : seed
        container.seed = normalizedSeed
        var rng = BKSeededRandom(seed: normalizedSeed)
        let preferredImageSources = !tintedBackgroundVariants.isEmpty
            ? tintedBackgroundVariants
            : [assets.backgrounds]
        let hasImageBackgrounds = preferredImageSources.contains { !$0.isEmpty }

        // 1) 50/50 choose + anti-streak breaker.
        let bit = ((normalizedSeed >> 17) ^ (normalizedSeed >> 41) ^ normalizedSeed) & 1
        var proposedStyle: BackgroundStyle = (bit == 0) ? .image : .dot
        if fromContainer == nil, hasImageBackgrounds {
            // Ensure first screen shows artwork background at least once.
            proposedStyle = .image
        }
        if !hasImageBackgrounds {
            proposedStyle = .dot
        } else if let last = lastStyle, lastStyleRunCount >= 1, proposedStyle == last {
            proposedStyle = (last == .dot) ? .image : .dot
        }
        container.style = proposedStyle
        let variantCount = max(1, tintedBackgroundVariants.count)
        container.bgVariantIndex = Int((normalizedSeed ^ 0x7A6C_2E43_5B91_F0D3) % UInt64(variantCount))

        container.backgroundToneLayer.frame = expandedBounds
        let isDark = harmonized.isDark
        let toneVariant = !harmonized.bgVariants.isEmpty
            ? harmonized.bgVariants[min(container.bgVariantIndex, harmonized.bgVariants.count - 1)]
            : harmonized.bgStops
        container.backgroundToneLayer.backgroundColor =
            toneVariant.first ?? (isDark ? NSColor.black.cgColor : NSColor.white.cgColor)
        container.backgroundToneLayer.opacity = isDark ? 0.30 : 0.18

        applyStyle(to: container, style: container.style, rng: &rng)
        let swatchResult = BKColorEngine.makeShapeSwatches(
            seed: normalizedSeed ^ 0xA54F_66D1_9E37_79B9,
            extracted: extractedPaletteForSwatches,
            fallback: BKArtBackgroundView.fallbackPalette,
            isDark: harmonized.isDark
        )
        container.shapeSwatches = swatchResult.colors.isEmpty ? harmonized.shapePool : swatchResult.colors
        container.swatchDiagnostics = swatchResult.diagnostics

        let count = rng.nextInt(in: 10...16)
        let chosenShapes = chooseShapeImages(count: count, rng: &rng)
        let plannedTints = makeShapeTintPlan(
            count: chosenShapes.count,
            swatches: container.shapeSwatches,
            rng: &rng
        )
        container.shapeTints = plannedTints

        let forbiddenRect = CGRect(
            x: bounds.width * 0.28,
            y: bounds.height * 0.22,
            width: bounds.width * 0.44,
            height: bounds.height * 0.50
        )

        for (shapeIndex, selectedShape) in chosenShapes.enumerated() {
            let base = min(bounds.width, bounds.height)
            let randomScale = CGFloat(rng.next(in: 0.50...1.80))
            let baseSide = base * randomScale * 0.22

            let minSpecialRandomScale: CGFloat = selectedShape.scaleMultiplier >= 3.0 ? 1.20
                : (selectedShape.scaleMultiplier >= 2.0 ? 0.95 : 0.50)
            let enforcedBaseSide = base * max(randomScale, minSpecialRandomScale) * 0.22
            let side = selectedShape.scaleMultiplier > 1.0
                ? (enforcedBaseSide * selectedShape.scaleMultiplier)
                : baseSide
            let point = selectedShape.isEdgePinned
                ? randomPinnedEdgePoint(side: side, rng: &rng)
                : randomEdgePoint(side: side, forbiddenRect: forbiddenRect, rng: &rng)

            let size = CGSize(width: side, height: side)
            let finalTint = plannedTints[shapeIndex]
            let shape = makeTintedShapeLayer(image: selectedShape.image, size: size, tint: finalTint)
            shape.position = point

            container.shapesRoot.addSublayer(shape)
            container.shapeLayers.append(shape)

            let driftX = selectedShape.isEdgePinned ? CGFloat(0) : CGFloat(rng.next(in: -12...12))
            let driftY = selectedShape.isEdgePinned ? CGFloat(0) : CGFloat(rng.next(in: -16...16))
            let phaseSpeed = selectedShape.isEdgePinned ? CGFloat(0) : CGFloat(rng.next(in: 0.35...0.95))
            let state = ShapeState(
                basePosition: point,
                driftX: driftX,
                driftY: driftY,
                phase: CGFloat(rng.next(in: 0...(Double.pi * 2))),
                phaseSpeed: phaseSpeed,
                angle: CGFloat(rng.next(in: 0...(Double.pi * 2))),
                angularSpeed: CGFloat(rng.next(in: -0.22...0.22))
            )
            container.shapeStates.append(state)
        }

        ensureLayerOrder(for: container)

#if DEBUG
        let minExpectedShapeCount = assets.shapes.isEmpty ? 0 : 10
        assert(container.shapeLayers.count >= minExpectedShapeCount)
        assert(container.shapesRoot.sublayers?.count ?? 0 >= minExpectedShapeCount)
#endif

        return container
    }

    private func commitStyleHistory(_ style: BackgroundStyle) {
        if lastStyle == style {
            lastStyleRunCount += 1
        } else {
            lastStyle = style
            lastStyleRunCount = 0
        }
    }

    private func applyStyle(
        to container: Container,
        style: BackgroundStyle,
        rng: inout BKSeededRandom
    ) {
        container.style = style

        switch style {
        case .image:
            if let dotRoot = container.dotRoot {
                dotRoot.removeFromSuperlayer()
            }
            container.dotSlots.forEach { $0.rootLayer.removeFromSuperlayer() }
            container.dotSlots.removeAll(keepingCapacity: false)
            container.dotGradient = nil
            container.dotRoot = nil
            container.backgroundToneLayer.isHidden = false

#if DEBUG
            assert(container.dotRoot == nil || container.dotRoot?.isHidden == true)
#endif

        case .dot:
            if container.dotRoot == nil {
                setupDotBackground(in: container, rng: &rng)
            }
            container.backgroundToneLayer.isHidden = true
        }

        ensureLayerOrder(for: container)
    }

    private func ensureLayerOrder(for container: Container) {
        container.layer.insertSublayer(container.backgroundLayer, at: 0)
        container.layer.insertSublayer(container.backgroundToneLayer, above: container.backgroundLayer)

        if let dotRoot = container.dotRoot {
            container.layer.insertSublayer(dotRoot, above: container.backgroundToneLayer)
            container.layer.insertSublayer(container.shapesRoot, above: dotRoot)
        } else {
            container.layer.insertSublayer(container.shapesRoot, above: container.backgroundToneLayer)
        }
    }

    private func chooseShapeImages(count: Int, rng: inout BKSeededRandom) -> [SelectedShape] {
        guard !assets.shapes.isEmpty else { return [] }
        var indexed = Array(assets.shapes.enumerated())
        indexed.shuffle(using: &rng)
        if indexed.count >= count {
            return Array(indexed.prefix(count)).map { pair in
                SelectedShape(
                    image: pair.element,
                    scaleMultiplier: assets.specialShapeScaleByIndex[pair.offset] ?? 1.0,
                    isEdgePinned: assets.edgePinnedShapeIndices.contains(pair.offset)
                )
            }
        }
        var output = indexed.map { pair in
            SelectedShape(
                image: pair.element,
                scaleMultiplier: assets.specialShapeScaleByIndex[pair.offset] ?? 1.0,
                isEdgePinned: assets.edgePinnedShapeIndices.contains(pair.offset)
            )
        }
        while output.count < count {
            let randomIndex = Int(rng.next(in: 0..<Double(assets.shapes.count)))
            output.append(
                SelectedShape(
                    image: assets.shapes[randomIndex],
                    scaleMultiplier: assets.specialShapeScaleByIndex[randomIndex] ?? 1.0,
                    isEdgePinned: assets.edgePinnedShapeIndices.contains(randomIndex)
                )
            )
        }
        return output
    }

    private func randomPinnedEdgePoint(side: CGFloat, rng: inout BKSeededRandom) -> CGPoint {
        let half = side * 0.5
        let overflowRatio = CGFloat(rng.next(in: 0.20...0.40))
        let overflow = half * overflowRatio

        let sidePick = rng.nextInt(in: 0...3)
        switch sidePick {
        case 0:  // top
            return CGPoint(
                x: CGFloat(rng.next(in: Double(-half)...Double(bounds.width + half))),
                y: bounds.height - half + overflow
            )
        case 1:  // bottom
            return CGPoint(
                x: CGFloat(rng.next(in: Double(-half)...Double(bounds.width + half))),
                y: half - overflow
            )
        case 2:  // left
            return CGPoint(
                x: half - overflow,
                y: CGFloat(rng.next(in: Double(-half)...Double(bounds.height + half)))
            )
        default:  // right
            return CGPoint(
                x: bounds.width - half + overflow,
                y: CGFloat(rng.next(in: Double(-half)...Double(bounds.height + half)))
            )
        }
    }

    private func nextShapeTint(
        from base: CGColor,
        rng: inout BKSeededRandom,
        hueJitterMax: CGFloat = 4,
        satJitterMax: CGFloat = 0.03,
        briJitterMax: CGFloat = 0.03
    ) -> CGColor {
        let hueRange: ClosedRange<Double> = -Double(hueJitterMax)...Double(hueJitterMax)
        let satRange: ClosedRange<Double> = -Double(satJitterMax)...Double(satJitterMax)
        let briRange: ClosedRange<Double> = -Double(briJitterMax)...Double(briJitterMax)
        return BKColorEngine.stabilize(
            color: base,
            kind: .shape,
            palette: harmonized,
            hueJitter: CGFloat(rng.next(in: hueRange)),
            saturationJitter: CGFloat(rng.next(in: satRange)),
            brightnessJitter: CGFloat(rng.next(in: briRange))
        )
    }

    private func makeShapeTintPlan(
        count: Int,
        swatches: [CGColor],
        rng: inout BKSeededRandom
    ) -> [CGColor] {
        guard count > 0 else { return [] }
        let sourceSwatches = swatches.isEmpty ? harmonized.shapePool : swatches
        guard !sourceSwatches.isEmpty else {
            return Array(repeating: harmonized.dotBase, count: count)
        }

        var plan: [CGColor] = []
        plan.reserveCapacity(count)

        var ordered = sourceSwatches
        ordered.shuffle(using: &rng)
        for index in 0..<count {
            let base = ordered[index % ordered.count]
            plan.append(nextShapeTint(from: base, rng: &rng))
        }
        return plan
    }

    private func retintShapes(in container: Container?) {
        guard let container, !container.shapeLayers.isEmpty else { return }
        let swatchSeed = (container.seed == 0 ? rebuildSeed : container.seed) ^ 0xB3D2_AE5F_9E37_79B9
        let swatchResult = BKColorEngine.makeShapeSwatches(
            seed: swatchSeed,
            extracted: extractedPaletteForSwatches,
            fallback: BKArtBackgroundView.fallbackPalette,
            isDark: harmonized.isDark
        )
        container.shapeSwatches = swatchResult.colors.isEmpty ? harmonized.shapePool : swatchResult.colors
        container.swatchDiagnostics = swatchResult.diagnostics
        var rng = BKSeededRandom(
            seed: swatchSeed
                ^ UInt64(truncatingIfNeeded: container.shapeLayers.count)
        )
        let plan = makeShapeTintPlan(
            count: container.shapeLayers.count,
            swatches: container.shapeSwatches,
            rng: &rng
        )
        container.shapeTints = plan
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, layer) in container.shapeLayers.enumerated() {
            let tint = plan[index]
            if let fill = layer.sublayers?.first {
                fill.backgroundColor = tint
            }
        }
        CATransaction.commit()
    }

    private func randomEdgePoint(
        side: CGFloat,
        forbiddenRect: CGRect,
        rng: inout BKSeededRandom
    ) -> CGPoint {
        let minDimension = max(1, min(bounds.width, bounds.height))
        let safeSide = min(max(side, 1), max(1, minDimension - 2))
        let half = safeSide * 0.5
        let xLower = half
        let xUpper = max(half, bounds.width - half)
        let yLower = half
        let yUpper = max(half, bounds.height - half)
        let xSpan = max(0, xUpper - xLower)
        let ySpan = max(0, yUpper - yLower)
        let edgeBandX = min(max(24, bounds.width * 0.18), xSpan)
        let edgeBandY = min(max(24, bounds.height * 0.18), ySpan)

        func randomBetween(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            let lo = min(a, b)
            let hi = max(a, b)
            return CGFloat(rng.next(in: Double(lo)...Double(hi)))
        }

        for _ in 0..<28 {
            let sidePick = rng.next(in: 0.0..<1.0)
            let point: CGPoint
            if sidePick < 0.30 {
                point = CGPoint(
                    x: randomBetween(xLower, xUpper),
                    y: randomBetween(yUpper - edgeBandY, yUpper)
                )
            } else if sidePick < 0.60 {
                point = CGPoint(
                    x: randomBetween(xLower, xUpper),
                    y: randomBetween(yLower, yLower + edgeBandY)
                )
            } else if sidePick < 0.80 {
                point = CGPoint(
                    x: randomBetween(xLower, xLower + edgeBandX),
                    y: randomBetween(yLower, yUpper)
                )
            } else {
                point = CGPoint(
                    x: randomBetween(xUpper - edgeBandX, xUpper),
                    y: randomBetween(yLower, yUpper)
                )
            }

            let frame = CGRect(
                x: point.x - half,
                y: point.y - half,
                width: safeSide,
                height: safeSide
            )
            if !frame.intersects(forbiddenRect) {
                return point
            }
        }

        let fallbackX = min(max(half + 16, xLower), xUpper)
        let fallbackY = min(max(bounds.height - half - 16, yLower), yUpper)
        return CGPoint(
            x: fallbackX,
            y: fallbackY
        )
    }

    private func makeTintedShapeLayer(image: CGImage, size: CGSize, tint: CGColor) -> CALayer {
        let root = CALayer()
        // Geometry Fix: bounds origin must be 0,0
        root.bounds = CGRect(origin: .zero, size: size)
        // Anchor point default is 0.5,0.5, so setting position externally works as center
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
        guard window != nil, !isPausedFrozen else { return }
        prewarmTransitionAssetsIfNeeded()
        startBackgroundTimerIfNeeded()
        startShapeTimerIfNeeded()
        startDotTimerIfNeeded()
        if autoTransitionTimer == nil && speedTarget > 0.01 {
            scheduleNextAutoTransition()
        }
        if isTransitionInFlight && transitionTimer == nil && speedTarget > 0.01 {
            startTransitionTimer()
        }
    }

    private func startBackgroundTimerIfNeeded() {
        guard backgroundTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 0.7)
        timer.setEventHandler { [weak self] in
            self?.tickBackground()
        }
        timer.resume()
        backgroundTimer = timer
    }

    private func startDotTimerIfNeeded() {
        guard dotTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 15.0)
        timer.setEventHandler { [weak self] in
            self?.tickDotAnimation()
        }
        timer.resume()
        dotTimer = timer
    }

    private func startShapeTimerIfNeeded() {
        guard shapeTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 12.0)
        timer.setEventHandler { [weak self] in
            self?.tickShapes()
        }
        timer.resume()
        shapeTimer = timer
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
        speedRampTimer?.cancel()
        speedRampTimer = nil
        isTransitionInFlight = false
        didPauseBackgroundTimerForTransition = false
        didPauseDotTimerForTransition = false
        isPausedFrozen = false
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

    private var shouldFreezeVisualUpdates: Bool {
        speedTarget <= 0.01 || speedCurrent <= 0.01
    }

    private func startSpeedRampTimerIfNeeded() {
        guard speedRampTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60.0)
        timer.setEventHandler { [weak self] in
            self?.tickSpeedRamp()
        }
        timer.resume()
        speedRampTimer = timer
    }

    private func stopSpeedRampTimer() {
        speedRampTimer?.cancel()
        speedRampTimer = nil
    }

    private func tickSpeedRamp() {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastTickTime, 1.0 / 240.0), 0.25)
        lastTickTime = now

        let diff = speedTarget - speedCurrent
        if abs(diff) > 0.0001 {
            let k = diff < 0 ? 4.0 : 5.5
            let alpha = 1 - exp(-k * dt)
            speedCurrent += diff * alpha
        }

        if abs(speedTarget - speedCurrent) < 0.01 {
            speedCurrent = speedTarget
            if speedTarget <= 0.01 {
                freezeAnimationTimers()
            } else {
                resumeAnimationTimersAfterFreeze()
            }
            stopSpeedRampTimer()
        }
    }

    private func freezeAnimationTimers() {
        guard !isPausedFrozen else { return }
        isPausedFrozen = true
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

    private func resumeAnimationTimersAfterFreeze() {
        guard isPausedFrozen else { return }
        isPausedFrozen = false
        startTimersIfNeeded()
    }

    private func enterTransitionPerformanceMode(currentStyle: BackgroundStyle) {
        isTransitionInFlight = true

        if backgroundTimer != nil {
            backgroundTimer?.cancel()
            backgroundTimer = nil
            didPauseBackgroundTimerForTransition = true
        } else {
            didPauseBackgroundTimerForTransition = false
        }

        if currentStyle != .dot, dotTimer != nil {
            dotTimer?.cancel()
            dotTimer = nil
            didPauseDotTimerForTransition = true
        } else {
            didPauseDotTimerForTransition = false
        }
    }

    private func exitTransitionPerformanceMode() {
        isTransitionInFlight = false

        if didPauseBackgroundTimerForTransition {
            didPauseBackgroundTimerForTransition = false
            if speedTarget > 0.01 {
                startBackgroundTimerIfNeeded()
            }
        }

        if didPauseDotTimerForTransition {
            didPauseDotTimerForTransition = false
            if speedTarget > 0.01 {
                startDotTimerIfNeeded()
            }
        }

        if pendingBoundsRebuild {
            pendingBoundsRebuild = false
            rebuildForCurrentBounds()
        }
    }

    private func tickBackground() {
        let hasBackgrounds = tintedBackgroundVariants.contains { !$0.isEmpty } || !assets.backgrounds.isEmpty
        guard hasBackgrounds else { return }
        let phaseStep = speedCurrent
        guard phaseStep > 0.0001 else { return }
        backgroundPhaseFloat += phaseStep
        let nextPhase = Int(floor(backgroundPhaseFloat))
        guard nextPhase != backgroundPhase else { return }
        backgroundPhase = nextPhase
        applyCurrentBackgroundPhase()
    }

    private func updateDotGradient(_ container: Container) {
        guard let gradient = container.dotGradient else { return }
        gradient.colors = dotGradientStops()
    }

    private func dotGradientStops() -> [CGColor] {
        guard harmonized.isDark, isUltraDarkCover else {
            return harmonized.bgStops
        }
        return harmonized.bgStops.map { darkenForUltraDarkDot($0) }
    }

    private var isUltraDarkCover: Bool {
        let luma = harmonized.imageCoverLuma
        return (luma < 0.36 && harmonized.areaDominantB < 0.30)
            || (luma < 0.30 && harmonized.grayScore > 0.70)
    }

    private func darkenForUltraDarkDot(_ color: CGColor) -> CGColor {
        guard let rgb = NSColor(cgColor: color)?.usingColorSpace(.deviceRGB) else { return color }
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let targetB = max(0.08, min(0.24, min(b * 0.58, b - 0.06)))
        let targetS = max(0.08, min(0.38, s * 0.92))
        return NSColor(deviceHue: h, saturation: targetS, brightness: targetB, alpha: a).cgColor
    }

    private func assignRandomColor(to slot: DotSlot, rng: inout BKSeededRandom) {
        let jitter = dotJitterBudget()
        let hueJitter = CGFloat(rng.next(in: jitter.hue))
        let satJitter = CGFloat(rng.next(in: jitter.saturation))
        let briJitter = CGFloat(rng.next(in: jitter.brightness))
        let finalColor = BKColorEngine.stabilize(
            color: harmonized.dotBase,
            kind: .dot,
            palette: harmonized,
            hueJitter: hueJitter,
            saturationJitter: satJitter,
            brightnessJitter: briJitter
        )
        let withAlpha = (NSColor(cgColor: finalColor) ?? .white).withAlphaComponent(0.90).cgColor
        slot.color = withAlpha

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        slot.cellBig?.fillColor = slot.color
        slot.cellSmall?.fillColor = slot.color
        CATransaction.commit()
    }

    private func scheduleNextAutoTransition() {
        autoTransitionTimer?.cancel()

        // Dynamic interval: 20s if Dot (to let animation breathe), 15s if Image
        let interval: TimeInterval = (fromContainer?.style == .dot) ? 20.0 : 15.0

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: .infinity)  // One-shot logic effectively via reschedule
        timer.setEventHandler { [weak self] in
            self?.tickAutoTransition()
        }
        timer.resume()
        autoTransitionTimer = timer
    }

    private func tickAutoTransition() {
        guard speedTarget > 0.01, speedCurrent > 0.01 else {
            autoTransitionTimer?.cancel()
            autoTransitionTimer = nil
            return
        }
        let seed = nextTransitionSeed()
        triggerTransition(seed: seed)

        // Reschedule based on new state (after transition starts)
        // Note: triggerTransition updates toContainer, but fromContainer is still the old one until finalize.
        // We ideally want to schedule based on the *next* container's style,
        // but 'toContainer' is the one entering.
        // Let's rely on the fact that when finalize happens, loop continues.
        // Actually, triggerTransition creates toContainer. Let's peek at toContainer style for next delay?
        // Or simple: Just schedule next tick.
        scheduleNextAutoTransition()
    }

    private func applyCurrentBackgroundPhase() {
        applyBackgroundPhase(to: fromContainer)
        applyBackgroundPhase(to: toContainer)
    }

    private func applyBackgroundPhase(to container: Container?) {
        guard let container else { return }

        var styleRng = BKSeededRandom(
            seed: rebuildSeed
                ^ UInt64(bitPattern: Int64(container.style.rawValue))
                ^ UInt64(bitPattern: Int64(backgroundPhase))
        )
        applyStyle(to: container, style: container.style, rng: &styleRng)

        if container.style == .dot {
            container.backgroundLayer.contents = nil
            container.backgroundLayer.backgroundColor = harmonized.bgStops.first ?? NSColor.black.cgColor
            updateDotGradient(container)
            return
        }

        let variantSources = !tintedBackgroundVariants.isEmpty
            ? tintedBackgroundVariants
            : [assets.backgrounds]
        guard !variantSources.isEmpty else { return }
        let variantIndex = min(max(0, container.bgVariantIndex), variantSources.count - 1)
        var source = variantSources[variantIndex]
        if source.isEmpty {
            source = assets.backgrounds
        }
        guard !source.isEmpty else { return }
        let sourceIndex = backgroundPhase % source.count
        let image = source[sourceIndex]
        container.backgroundLayer.contentsGravity = .resizeAspectFill
        container.backgroundLayer.contentsScale =
            window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        container.backgroundLayer.contents = image

#if DEBUG
        assert(container.dotRoot == nil || container.dotRoot?.isHidden == true)
        assert(container.backgroundLayer.contents != nil)
        let minExpectedShapeCount = assets.shapes.isEmpty ? 0 : 10
        assert(container.shapesRoot.sublayers?.count ?? 0 >= minExpectedShapeCount)
#endif
    }

    private func tickShapes() {
        let dt = CGFloat((1.0 / 12.0) * speedCurrent)
        guard dt > 0.0001 else { return }
        updateShapes(for: fromContainer, dt: dt)
        updateShapes(for: toContainer, dt: dt)
    }

    private func tickDotAnimation() {
        let dt = (1.0 / 15.0) * speedCurrent
        guard dt > 0.0001 else { return }
        tickDotBackground(for: fromContainer, dt: dt)
        tickDotBackground(for: toContainer, dt: dt)
    }

    private func updateShapes(for container: Container?, dt: CGFloat) {
        guard let container else { return }
        guard !container.shapeLayers.isEmpty else { return }
        guard container.shapeLayers.count == container.shapeStates.count else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

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

        let progressStep = speedCurrent
        guard progressStep > 0.0001 else { return }
        maskFrameProgress += progressStep
        let nextFrameIndex = Int(floor(maskFrameProgress))
        if nextFrameIndex >= maskFrames.count {
            finalizeTransition()
            return
        }
        guard nextFrameIndex != maskFrameIndex else { return }
        maskFrameIndex = nextFrameIndex

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.contents = maskFrames[maskFrameIndex]
        CATransaction.commit()

        toContainer.layer.mask = maskLayer
    }

    private func finalizeTransition() {
        guard let next = toContainer else {
            stopTransitionTimer()
            exitTransitionPerformanceMode()
            return
        }
        next.layer.mask = nil
        transitionMaskLayer = nil
        fromContainer?.layer.removeFromSuperlayer()
        fromContainer = next
        toContainer = nil
        commitStyleHistory(next.style)
        stopTransitionTimer()
        exitTransitionPerformanceMode()
    }

    private struct DarkToneMapConfig {
        let exposureDown: CGFloat
        let p4Y: CGFloat
        let saturation: CGFloat
        let contrast: CGFloat
        let shadowLift: CGFloat
        let highlightAmount: CGFloat
        let detailAlpha: CGFloat
        let targetBgB: CGFloat
        let shapeReferenceB: CGFloat
        let ultraDark: Bool
    }

    private struct ImageVariantTuning {
        let avgS: CGFloat
        let hueSpread: CGFloat
        let richScore: CGFloat
        let mapAlpha: CGFloat
        let originalSaturation: CGFloat
        let composedSaturationBoost: CGFloat
    }

    private func makeTintedBackgroundVariants(from source: [CGImage]) -> [[CGImage]] {
        guard !source.isEmpty else { return [] }
        let variants = backgroundToneVariants()
        let toneStops = variants.first ?? [BKArtBackgroundView.fallbackPalette[0]]
        guard let mapImage = makeColorMapImage(colors: toneStops) else { return [source] }
        let darkConfig = harmonized.isDark ? makeDarkToneMapConfig() : nil
        let tuning = imageVariantTuning(for: toneStops)
        let variantImages = source.compactMap { image in
            let input = CIImage(cgImage: image)
            let grayscale = input.applyingFilter(
                "CIColorControls",
                parameters: [
                    kCIInputSaturationKey: 0.0,
                    kCIInputContrastKey: 1.08,
                    kCIInputBrightnessKey: 0.0,
                ]
            )

            let mapped = grayscale.applyingFilter(
                "CIColorMap",
                parameters: ["inputGradientImage": mapImage]
            )
            let mappedSoftAlpha = mapped.applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: tuning.mapAlpha)
                ]
            )
            let desaturatedOriginal = input.applyingFilter(
                "CIColorControls",
                parameters: [
                    kCIInputSaturationKey: tuning.originalSaturation,
                    kCIInputContrastKey: 1.10,
                    kCIInputBrightnessKey: 0.0,
                ]
            )
            var composed = mappedSoftAlpha.applyingFilter(
                "CISourceOverCompositing",
                parameters: [kCIInputBackgroundImageKey: desaturatedOriginal]
            )
            if abs(tuning.composedSaturationBoost - 1.0) > 0.01 {
                composed = composed.applyingFilter(
                    "CIColorControls",
                    parameters: [
                        kCIInputSaturationKey: tuning.composedSaturationBoost,
                        kCIInputContrastKey: 1.02,
                        kCIInputBrightnessKey: 0.0,
                    ]
                )
            }
            let finalImage: CIImage
            if let darkConfig {
                finalImage = toneMap(
                    image: composed,
                    isDark: true,
                    config: darkConfig
                )
            } else {
                finalImage = composed
            }
            return ciContext.createCGImage(finalImage, from: input.extent)
        }
        return variantImages.isEmpty ? [source] : [variantImages]
    }

    private func makeDarkToneMapConfig() -> DarkToneMapConfig {
        let coverLuma = max(0, min(1, harmonized.imageCoverLuma))
        let shapeReferenceB = max(0.10, min(1.0, (harmonized.fgBRange.lowerBound + harmonized.fgBRange.upperBound) * 0.5))
        let rawBgTarget = (harmonized.bgBRange.lowerBound + harmonized.bgBRange.upperBound) * 0.5
        var targetBgB = max(0.10, min(shapeReferenceB - 0.10, rawBgTarget))
        let ultraDark = isUltraDarkCover
        if coverLuma < 0.22 {
            targetBgB = max(0.10, min(targetBgB, 0.16))
        }
        if coverLuma < 0.14 {
            targetBgB = max(0.10, min(targetBgB, 0.14))
        }
        if ultraDark {
            let t = max(0, min(1, (0.36 - coverLuma) / 0.36))
            let ultraTarget = lerp(0.15, 0.11, t: t)
            targetBgB = max(0.10, min(targetBgB, ultraTarget))
        }
        let darkNeutralBias = (harmonized.grayScore > 0.68 || harmonized.areaDominantS < 0.16)
            && coverLuma < 0.40
            && !harmonized.accentEnabled

        let exposureDown: CGFloat
        if coverLuma < 0.22 {
            exposureDown = lerp(-0.90, -0.35, t: coverLuma / 0.22)
        } else {
            exposureDown = lerp(-0.35, -0.10, t: (coverLuma - 0.22) / 0.78)
        }

        let exposureBias2 = max(
            -1.6,
            min(0.0, log2(max(0.08, targetBgB) / 0.30))
        )
        var finalExposure = min(exposureDown, exposureBias2)
        if darkNeutralBias {
            finalExposure = min(finalExposure - 0.28, -0.55)
        }
        if ultraDark {
            let t = max(0, min(1, (0.36 - coverLuma) / 0.36))
            finalExposure = min(finalExposure - (0.24 + 0.32 * t), -0.82)
        }
        finalExposure = max(-2.0, min(-0.1, finalExposure))
        var p4Y: CGFloat = coverLuma < 0.14 ? 0.80 : 0.86
        if darkNeutralBias {
            p4Y = min(p4Y, coverLuma < 0.16 ? 0.74 : 0.78)
        }
        if ultraDark {
            let t = max(0, min(1, (0.36 - coverLuma) / 0.36))
            p4Y = min(p4Y, lerp(0.78, 0.68, t: t))
        }
        let avgPaletteSat = averagePaletteSaturation()
        let bgVariantSat = averageBackgroundVariantSaturation()
        var saturation = max(0.88, min(1.10, 0.90 + 0.45 * max(avgPaletteSat, bgVariantSat)))
        if darkNeutralBias {
            saturation = min(saturation, 0.98)
        }
        if ultraDark {
            saturation = min(saturation, 1.02)
        }
        var contrast = max(1.02, min(1.10, 1.10 - 0.08 * coverLuma))
        if darkNeutralBias {
            contrast = max(1.05, min(1.10, contrast + 0.03))
        }
        if ultraDark {
            contrast = max(contrast, 1.09)
        }

        let shadowLift: CGFloat = ultraDark ? 0.16 : 0.12
        let highlightAmount: CGFloat = ultraDark ? 0.72 : 0.80
        var detailAlpha: CGFloat = ultraDark ? 0.16 : 0.08
        if darkNeutralBias {
            detailAlpha = min(0.20, detailAlpha + 0.02)
        }

        return DarkToneMapConfig(
            exposureDown: finalExposure,
            p4Y: p4Y,
            saturation: saturation,
            contrast: contrast,
            shadowLift: shadowLift,
            highlightAmount: highlightAmount,
            detailAlpha: detailAlpha,
            targetBgB: targetBgB,
            shapeReferenceB: shapeReferenceB,
            ultraDark: ultraDark
        )
    }

    private func toneMap(
        image: CIImage,
        isDark: Bool,
        config: DarkToneMapConfig
    ) -> CIImage {
        guard isDark else { return image }
        let exposed = image.applyingFilter(
            "CIExposureAdjust",
            parameters: [kCIInputEVKey: config.exposureDown]
        )
        let curved = exposed.applyingFilter(
            "CIToneCurve",
            parameters: [
                "inputPoint0": CIVector(x: 0.00, y: 0.02),
                "inputPoint1": CIVector(x: 0.25, y: 0.22),
                "inputPoint2": CIVector(x: 0.50, y: 0.45),
                "inputPoint3": CIVector(x: 0.75, y: 0.66),
                "inputPoint4": CIVector(x: 1.00, y: config.p4Y),
            ]
        )
        let tuned = curved.applyingFilter(
            "CIColorControls",
            parameters: [
                kCIInputSaturationKey: config.saturation,
                kCIInputContrastKey: config.contrast,
                kCIInputBrightnessKey: 0.0,
            ]
        )
        let shaped = tuned.applyingFilter(
            "CIHighlightShadowAdjust",
            parameters: [
                "inputShadowAmount": config.shadowLift,
                "inputHighlightAmount": config.highlightAmount,
            ]
        )
        let detail = image.applyingFilter(
            "CIColorControls",
            parameters: [
                kCIInputSaturationKey: 0.0,
                kCIInputContrastKey: 1.12,
                kCIInputBrightnessKey: 0.0,
            ]
        )
        let detailLayer = detail.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: config.detailAlpha)
            ]
        )
        return detailLayer.applyingFilter(
            "CISourceOverCompositing",
            parameters: [kCIInputBackgroundImageKey: shaped]
        )
    }

    private func averagePaletteSaturation() -> CGFloat {
        let all = harmonized.shapePool + harmonized.bgStops + [harmonized.dotBase]
        let sats: [CGFloat] = all.compactMap { color in
            guard let rgb = NSColor(cgColor: color)?.usingColorSpace(.deviceRGB) else { return nil }
            var h: CGFloat = 0
            var s: CGFloat = 0
            var b: CGFloat = 0
            var a: CGFloat = 0
            rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return s
        }
        guard !sats.isEmpty else { return 0.5 }
        return sats.reduce(0, +) / CGFloat(sats.count)
    }

    private func averageBackgroundVariantSaturation() -> CGFloat {
        let all = harmonized.bgVariants.flatMap { $0 }
        let sats: [CGFloat] = all.compactMap { color in
            guard let rgb = NSColor(cgColor: color)?.usingColorSpace(.deviceRGB) else { return nil }
            var h: CGFloat = 0
            var s: CGFloat = 0
            var b: CGFloat = 0
            var a: CGFloat = 0
            rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return s
        }
        guard !sats.isEmpty else { return 0.30 }
        return sats.reduce(0, +) / CGFloat(sats.count)
    }

    private func imageVariantTuning(for colors: [NSColor]) -> ImageVariantTuning {
        let hsbs = colors.compactMap { color -> (h: CGFloat, s: CGFloat, b: CGFloat)? in
            guard let rgb = color.usingColorSpace(.deviceRGB) else { return nil }
            var h: CGFloat = 0
            var s: CGFloat = 0
            var b: CGFloat = 0
            var a: CGFloat = 0
            rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return ((h * 360).truncatingRemainder(dividingBy: 360), s, b)
        }

        guard !hsbs.isEmpty else {
            return ImageVariantTuning(
                avgS: 0.20,
                hueSpread: 0,
                richScore: 0,
                mapAlpha: 0.66,
                originalSaturation: 0.22,
                composedSaturationBoost: 1.0
            )
        }

        let avgS = hsbs.map(\.s).reduce(0, +) / CGFloat(hsbs.count)
        var hueSpread: CGFloat = 0
        if hsbs.count > 1 {
            for i in 0..<(hsbs.count - 1) {
                for j in (i + 1)..<hsbs.count {
                    var d = abs(hsbs[i].h - hsbs[j].h).truncatingRemainder(dividingBy: 360)
                    if d > 180 { d = 360 - d }
                    hueSpread = max(hueSpread, d)
                }
            }
        }

        let richScore = max(
            0,
            min(
                1,
                (avgS - 0.12) / 0.38 * 0.6 + (hueSpread / 90) * 0.4
            )
        )
        let mapAlpha = lerp(0.62, 0.82, t: richScore)
        let originalSaturation = lerp(0.18, 0.34, t: richScore)
        let composedBoost = lerp(0.96, 1.12, t: richScore)

        return ImageVariantTuning(
            avgS: avgS,
            hueSpread: hueSpread,
            richScore: richScore,
            mapAlpha: mapAlpha,
            originalSaturation: originalSaturation,
            composedSaturationBoost: composedBoost
        )
    }

    private func backgroundToneVariants() -> [[NSColor]] {
        let variantStops = !harmonized.bgVariants.isEmpty ? harmonized.bgVariants : [harmonized.bgStops]
        let fallback = BKArtBackgroundView.fallbackPalette

        let normalized = variantStops.map { stops -> [NSColor] in
            let base = stops.compactMap { NSColor(cgColor: $0)?.usingColorSpace(.deviceRGB) }
            let colors = base.isEmpty
                ? [fallback[0].usingColorSpace(.deviceRGB) ?? fallback[0]]
                : base
            if harmonized.isGrayscaleCover {
                return colors
            }
            return colors.map { enforceImageToneFloor($0) }
        }.filter { !$0.isEmpty }

        return normalized.isEmpty
            ? [[fallback[0].usingColorSpace(.deviceRGB) ?? fallback[0]]]
            : normalized
    }

    private func enforceImageToneFloor(_ color: NSColor) -> NSColor {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let minS: CGFloat = harmonized.isDark
            ? max(0.10, min(0.28, harmonized.fgSRange.lowerBound - 0.10))
            : 0.18
        let minB: CGFloat = harmonized.isDark ? 0.10 : 0.22
        let clampedS = max(minS, min(1.0, s))
        let clampedB = max(minB, min(1.0, b))
        return NSColor(deviceHue: h, saturation: clampedS, brightness: clampedB, alpha: a)
    }

    private func makeColorMapImage(colors: [NSColor]) -> CIImage? {
        guard !colors.isEmpty else { return nil }
        let width = 256
        let height = 1
        let bytesPerPixel = 4
        var data = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let normalizedStops = colors.map { $0.usingColorSpace(.deviceRGB) ?? $0 }
        let stopCount = normalizedStops.count

        for x in 0..<width {
            let t = CGFloat(x) / CGFloat(width - 1)
            let color: NSColor
            if stopCount == 1 {
                color = normalizedStops[0]
            } else {
                let segmentCount = stopCount - 1
                let position = t * CGFloat(segmentCount)
                let left = min(segmentCount - 1, max(0, Int(floor(position))))
                let right = min(segmentCount, left + 1)
                let localT = position - CGFloat(left)
                color = blend(normalizedStops[left], normalizedStops[right], t: localT)
            }

            let rgb = color.usingColorSpace(.deviceRGB) ?? color
            let idx = x * bytesPerPixel
            data[idx + 0] = UInt8(clamp(rgb.redComponent) * 255.0)
            data[idx + 1] = UInt8(clamp(rgb.greenComponent) * 255.0)
            data[idx + 2] = UInt8(clamp(rgb.blueComponent) * 255.0)
            data[idx + 3] = 255
        }

        guard
            let provider = CGDataProvider(data: Data(data) as CFData),
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

    private func lerp(_ a: CGFloat, _ b: CGFloat, t: CGFloat) -> CGFloat {
        let p = max(0, min(1, t))
        return a + (b - a) * p
    }

    private func nextTransitionSeed() -> UInt64 {
        transitionSeedCounter &+= 1
        return rebuildSeed &+ (transitionSeedCounter &* 0x9E37_79B9_7F4A_7C15)
    }

    private var expandedBounds: CGRect {
        bounds.insetBy(dx: -1.0, dy: -1.0)
    }

    private func prewarmTransitionAssetsIfNeeded() {
        guard !didPrewarmMaskFrames else { return }
        guard !assets.maskFrames.isEmpty else { return }
        didPrewarmMaskFrames = true
        _ = resolvedMaskFrames()
    }

    private func resolvedMaskFrames() -> [CGImage] {
        assets.maskFrames
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
        container.layer.insertSublayer(root, above: container.backgroundToneLayer)

        // A) Gradient Background (Shared)
        let gradient = CAGradientLayer()
        gradient.frame = root.bounds
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        container.dotGradient = gradient
        root.addSublayer(gradient)
        updateDotGradient(container)

        // Initialize first Slot.
        createAndAddSlot(to: container, rng: &rng, overlapT: 0.88, initialIdleDelay: 0)
        ensureLayerOrder(for: container)
    }

    private func createAndAddSlot(
        to container: Container,
        rng: inout BKSeededRandom,
        overlapT: Double? = nil,
        initialIdleDelay: TimeInterval? = nil
    ) {
        guard let root = container.dotRoot else { return }

        // 1. Random Parameters
        let baseSize = max(bounds.width, bounds.height)
        let r = baseSize * 0.30
        // Use marginMul 1.05 for start (closer/faster entry), 1.45 for end
        let start = randomOffscreenPoint(radius: r, rng: &rng, marginMul: 1.05)
        let end = randomOffscreenPoint(radius: r, rng: &rng, marginMul: 1.45)

        let cp1 = CGPoint(
            x: rng.next(in: Double(bounds.minX)...Double(bounds.maxX)),
            y: rng.next(in: Double(bounds.minY)...Double(bounds.maxY))
        )
        let cp2 = CGPoint(
            x: rng.next(in: Double(bounds.minX)...Double(bounds.maxX)),
            y: rng.next(in: Double(bounds.minY)...Double(bounds.maxY))
        )
        // Slower duration: 12.0 ... 17.0 (Don't go too slow)
        let duration = rng.next(in: 12.0...17.0)

        // Lead-in overlap: 0.55 ... 0.75 (Earlier spawn)
        var leadIn = overlapT ?? rng.next(in: 0.55...0.75)
        // If really slow, pull lead-in even earlier
        if duration > 16.0 {
            leadIn = max(0.50, leadIn - 0.05)
        }

        let idleDelay = max(0, initialIdleDelay ?? rng.next(in: 0.10...0.45))
        let anim = DotAnimState(
            motion: .idle(idleDelay),
            start: start, cp1: cp1, cp2: cp2, end: end,
            duration: duration,
            leadInOverlapT: leadIn
        )

        // 2. Create Slot
        let dotBaseRadius = baseSize * CGFloat(rng.next(in: 0.26...0.34))
        let slot = DotSlot(anim: anim, baseRadius: dotBaseRadius)
        slot.radiusBig = CGFloat(rng.next(in: 5.0...6.2))
        slot.radiusSmall = CGFloat(rng.next(in: 3.0...4.0))
        slot.maskBaseRadiusBig = max(1, dotBaseRadius * 0.75)
        slot.maskBaseRadiusSmall = max(1, dotBaseRadius)

        slot.rootLayer.frame = root.bounds

        // 3. Build Layer Tree for this Slot
        // We need new Grid layers specific to this slot to allow independent masking and coloring
        let dotSpacing: CGFloat = 30
        let cols = Int(baseSize / dotSpacing) + 6
        let rows = Int(baseSize / dotSpacing) + 6

        // Grid 1 (Big)
        let grid1 = CALayer()
        grid1.frame = root.bounds
        let cell1 = addDotGrid(
            to: grid1, cols: cols, rows: rows, spacing: dotSpacing, radius: slot.radiusBig,
            opacity: 0.90)
        slot.rootLayer.addSublayer(grid1)
        slot.cellBig = cell1

        let mask1 = CAShapeLayer()
        mask1.fillColor = NSColor.black.cgColor
        mask1.bounds = CGRect(
            x: 0,
            y: 0,
            width: slot.maskBaseRadiusBig * 2,
            height: slot.maskBaseRadiusBig * 2
        )
        mask1.path = CGPath(ellipseIn: mask1.bounds, transform: nil)
        mask1.position = start
        mask1.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        grid1.mask = mask1
        slot.maskBig = mask1

        // Grid 2 (Small)
        let grid2 = CALayer()
        grid2.frame = root.bounds
        let cell2 = addDotGrid(
            to: grid2, cols: cols, rows: rows, spacing: dotSpacing, radius: slot.radiusSmall,
            opacity: 0.50)
        slot.rootLayer.addSublayer(grid2)
        slot.cellSmall = cell2

        let mask2 = CAShapeLayer()
        mask2.fillColor = NSColor.black.cgColor
        mask2.bounds = CGRect(
            x: 0,
            y: 0,
            width: slot.maskBaseRadiusSmall * 2,
            height: slot.maskBaseRadiusSmall * 2
        )
        mask2.path = CGPath(ellipseIn: mask2.bounds, transform: nil)
        mask2.position = start
        mask2.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        grid2.mask = mask2
        slot.maskSmall = mask2

        // 4. Add to container. Tint is assigned when this slot enters moving.
        root.addSublayer(slot.rootLayer)
        container.dotSlots.append(slot)
    }

    private struct JitterBudget {
        let hue: ClosedRange<Double>
        let saturation: ClosedRange<Double>
        let brightness: ClosedRange<Double>
    }

    private func dotJitterBudget() -> JitterBudget {
        if harmonized.isGrayscaleCover {
            return JitterBudget(hue: -6...6, saturation: -0.02...0.02, brightness: -0.02...0.02)
        }
        if harmonized.isNearGray {
            return JitterBudget(hue: -12...12, saturation: -0.03...0.03, brightness: -0.03...0.03)
        }
        switch harmonized.complexity {
        case .monochrome:
            return JitterBudget(hue: -6...6, saturation: -0.02...0.02, brightness: -0.02...0.02)
        case .low:
            return JitterBudget(hue: -3...3, saturation: -0.03...0.03, brightness: -0.03...0.03)
        case .medium, .high:
            return JitterBudget(hue: -6...6, saturation: -0.04...0.04, brightness: -0.04...0.04)
        }
    }

    private func dotColorSeed(for slot: DotSlot) -> UInt64 {
        let sx = UInt64(bitPattern: Int64((Double(slot.anim.start.x) * 1000).rounded()))
        let sy = UInt64(bitPattern: Int64((Double(slot.anim.start.y) * 1000).rounded()))
        let ex = UInt64(bitPattern: Int64((Double(slot.anim.end.x) * 1000).rounded()))
        let ey = UInt64(bitPattern: Int64((Double(slot.anim.end.y) * 1000).rounded()))
        return
            sx
            ^ (sy &* 0x9E37_79B9_7F4A_7C15)
            ^ (ex &* 0xBF58_476D_1CE4_E5B9)
            ^ (ey &* 0x94D0_49BB_1331_11EB)
    }

    @discardableResult
    private func addDotGrid(
        to parent: CALayer, cols: Int, rows: Int, spacing: CGFloat, radius: CGFloat, opacity: Float,
        offset: CGPoint = .zero
    ) -> CAShapeLayer {
        let dot = CAShapeLayer()
        dot.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        dot.path = CGPath(ellipseIn: dot.bounds, transform: nil)
        // Default neutral color to avoid white flash before slot tint is assigned.
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

    private func tickDotBackground(for container: Container?, dt: Double) {
        guard let container, container.style == .dot, container.dotRoot != nil else { return }
        var slotsToRemove: [Int] = []
        var shouldSpawnNext = false
        var lastSlotRng: BKSeededRandom?

        // Iterate slots
        for (index, slot) in container.dotSlots.enumerated() {
            switch slot.anim.motion {
            case .idle(let remaining):
                let next = remaining - dt
                if next <= 0 {
                    var recolorRng = BKSeededRandom(
                        seed: rebuildSeed
                            ^ dotColorSeed(for: slot)
                            ^ UInt64(bitPattern: Int64(Double(backgroundPhase) * 131.0))
                    )
                    assignRandomColor(to: slot, rng: &recolorRng)
                    slot.anim.motion = .moving(0)
                } else {
                    slot.anim.motion = .idle(next)
                }

            case .moving(let t):
                let step = dt / slot.anim.duration
                let nextT = t + step

                // LEAD-IN LOGIC: If this is the "latest" slot, check overlap overlapT
                if index == container.dotSlots.count - 1 {
                    if nextT >= slot.anim.leadInOverlapT && container.dotSlots.count < 2 {
                        shouldSpawnNext = true
                        let s = UInt64(bitPattern: Int64(slot.anim.end.x * 100 + slot.anim.end.y))
                        lastSlotRng = BKSeededRandom(seed: s ^ 0xDEAD_BEEF)
                    }
                }

                if nextT >= 1.0 {
                    slotsToRemove.append(index)
                    slot.anim.motion = .moving(1.0)
                } else {
                    slot.anim.motion = .moving(nextT)
                }

                // Visuals
                let pos = cubicBezier(
                    t: min(1.0, nextT), p0: slot.anim.start, p1: slot.anim.cp1, p2: slot.anim.cp2,
                    p3: slot.anim.end)

                var scale: CGFloat = 1.0
                if nextT < 0.25 {
                    scale = 0.6 + 0.4 * easeOutQuint(nextT / 0.25)
                } else if nextT > 0.8 {
                    scale = 1.0 - 0.4 * easeInQuint((nextT - 0.8) / 0.2)
                }

                let currentR =
                    (slot.baseRadius > 0
                        ? slot.baseRadius : max(bounds.width, bounds.height) * 0.30) * scale

                CATransaction.begin()
                CATransaction.setDisableActions(true)

                if let mask0 = slot.maskBig {
                    let targetR0 = max(1, currentR * 0.75)
                    let scale0 = targetR0 / max(1, slot.maskBaseRadiusBig)
                    mask0.position = pos
                    mask0.setAffineTransform(CGAffineTransform(scaleX: scale0, y: scale0))
                }
                if let mask1 = slot.maskSmall {
                    let targetR1 = max(1, currentR)
                    let scale1 = targetR1 / max(1, slot.maskBaseRadiusSmall)
                    mask1.position = pos
                    mask1.setAffineTransform(CGAffineTransform(scaleX: scale1, y: scale1))
                }

                CATransaction.commit()
            }
        }

        if shouldSpawnNext {
            var rng = lastSlotRng ?? BKSeededRandom(seed: UInt64(Date().timeIntervalSince1970))
            createAndAddSlot(to: container, rng: &rng)
        }

        for i in slotsToRemove.reversed() {
            let slot = container.dotSlots[i]
            slot.rootLayer.removeFromSuperlayer()
            container.dotSlots.remove(at: i)
        }

        // Safety: If somehow empty, spawn one
        if container.dotSlots.isEmpty {
            var rng = BKSeededRandom(seed: UInt64(Date().timeIntervalSince1970))
            createAndAddSlot(to: container, rng: &rng, initialIdleDelay: 0)
        }
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

    private func randomOffscreenPoint(
        radius: CGFloat, rng: inout BKSeededRandom, marginMul: CGFloat = 1.5
    ) -> CGPoint {
        // Pick a side: 0=top, 1=bottom, 2=left, 3=right
        let side = rng.nextInt(in: 0...3)
        // Explicitly force far offscreen.
        let margin = radius * marginMul

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
